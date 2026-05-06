defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc """
  Deterministic worker for Linear issues waiting on `prloop` review.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @type outcome :: :waiting | :resumed | :clean | {:blocked, String.t()} | {:error, term()}
  @type command_result :: {:ok, String.t()} | {:error, term()}

  @resumable_actions MapSet.new([
                       "resume",
                       "rerun_runner",
                       "commit_existing_diff",
                       "post_review_trigger",
                       "wait_for_review"
                     ])
  @blocked_actions MapSet.new(["manual_reconcile", "fix_precondition"])
  @failure_states MapSet.new(["failed", "error", "errored", "canceled", "cancelled"])

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(%Issue{} = issue, update_recipient \\ nil, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    runner = Keyword.get(opts, :command_runner, __MODULE__.SystemCommandRunner)

    Logger.info("Starting review monitor for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    outcome =
      with {:ok, workspace} <- workspace_for_issue(issue, worker_host, opts) do
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace)
        monitor_workspace(issue, workspace, runner, worker_host)
      end

    send_monitor_result(update_recipient, issue, outcome)

    case outcome do
      :clean -> :ok
      :waiting -> :ok
      :resumed -> :ok
      {:blocked, _reason} -> :ok
      {:error, reason} -> exit({:review_monitor_failed, reason})
    end
  end

  defmodule SystemCommandRunner do
    @moduledoc false

    alias SymphonyElixir.SSH

    @spec run(String.t(), [String.t()], keyword()) :: SymphonyElixir.ReviewMonitor.command_result()
    def run(command, args, opts \\ []) when is_binary(command) and is_list(args) do
      worker_host = Keyword.get(opts, :worker_host)

      if is_binary(worker_host) do
        run_remote(worker_host, command, args, opts)
      else
        run_local(command, args, opts)
      end
    end

    defp run_local(command, args, opts) do
      system_opts =
        opts
        |> Keyword.take([:cd])
        |> Keyword.put(:stderr_to_stdout, true)

      case System.cmd(command, args, system_opts) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:exit_status, status, output}}
      end
    rescue
      error in ErlangError -> {:error, error.original}
    end

    defp run_remote(worker_host, command, args, opts) do
      shell_command =
        opts
        |> Keyword.get(:cd)
        |> remote_command(command, args)

      case SSH.run(worker_host, shell_command, stderr_to_stdout: true) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, status}} -> {:error, {:exit_status, status, output}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp remote_command(nil, command, args), do: shell_join([command | args])
    defp remote_command(cwd, command, args), do: "cd #{shell_escape(cwd)} && " <> shell_join([command | args])

    defp shell_join(parts) do
      Enum.map_join(parts, " ", &shell_escape(to_string(&1)))
    end

    defp shell_escape(value) when is_binary(value) do
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp workspace_for_issue(issue, worker_host, opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) -> {:ok, workspace}
      _ -> Workspace.create_for_issue(issue, worker_host)
    end
  end

  defp monitor_workspace(%Issue{} = issue, workspace, runner, worker_host) do
    with {:ok, branch} <- resolve_branch(issue, workspace, runner, worker_host),
         {:ok, pr} <- resolve_pr(issue, workspace, branch, runner, worker_host),
         {:ok, status} <- prloop_status(workspace, branch, pr.ref, runner, worker_host) do
      handle_status(issue, workspace, branch, pr, status, runner, worker_host)
    else
      {:blocked, reason, evidence} ->
        block_issue(issue, reason, evidence)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_branch(%Issue{branch_name: issue_branch}, workspace, runner, worker_host) do
    case run_command(runner, "git", ["branch", "--show-current"], cd: workspace, worker_host: worker_host) do
      {:ok, branch} ->
        branch = String.trim(branch)

        cond do
          branch != "" -> {:ok, branch}
          is_binary(issue_branch) and String.trim(issue_branch) != "" -> {:ok, String.trim(issue_branch)}
          true -> {:blocked, "In Review requires a current git branch or Linear branch name", %{}}
        end

      {:error, reason} ->
        {:error, {:git_branch_failed, reason}}
    end
  end

  defp resolve_pr(issue, workspace, branch, runner, worker_host) do
    case pr_from_state_files(workspace, branch, runner, worker_host) do
      {:ok, pr} -> {:ok, pr}
      :not_found -> pr_from_gh(issue, workspace, branch, runner, worker_host)
      {:blocked, reason, evidence} -> {:blocked, reason, evidence}
    end
  end

  defp pr_from_state_files(workspace, branch, runner, worker_host) do
    with {:ok, git_dir} <- run_command(runner, "git", ["rev-parse", "--git-dir"], cd: workspace, worker_host: worker_host),
         state_root <- Path.join([workspace, String.trim(git_dir), "cloud-review-loop"]),
         {:ok, output} <-
           run_command(
             runner,
             "sh",
             ["-lc", "find #{shell_escape(state_root)} -type f -name '*.json' 2>/dev/null"],
             cd: workspace,
             worker_host: worker_host
           ) do
      prs =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&read_prloop_state_file(&1, branch, workspace, runner, worker_host))
        |> Enum.uniq_by(& &1.ref)

      case prs do
        [pr] -> {:ok, pr}
        [] -> :not_found
        _ -> {:blocked, "multiple prloop state files match this worktree and branch", %{state_files: Enum.map(prs, & &1.state_file)}}
      end
    else
      {:error, _reason} -> :not_found
    end
  end

  defp read_prloop_state_file(path, branch, workspace, runner, worker_host) do
    with {:ok, raw} <- run_command(runner, "cat", [path], cd: workspace, worker_host: worker_host),
         {:ok, data} <- Jason.decode(raw),
         true <- state_matches?(data, branch, workspace),
         {:ok, pr} <- pr_from_state_data(data) do
      [Map.put(pr, :state_file, path)]
    else
      _ -> []
    end
  end

  defp state_matches?(data, branch, workspace) do
    values = flattened_values(data)
    branches = values_for_keys(values, ["branch", "headRefName", "head_ref_name"])
    worktrees = values_for_keys(values, ["worktree", "worktreePath", "worktree_path"])
    branch_match? = branches == [] or branch in branches
    worktree_match? = worktrees == [] or Path.expand(workspace) in Enum.map(worktrees, &Path.expand/1)

    branch_match? and worktree_match?
  end

  defp pr_from_state_data(data) do
    values = flattened_values(data)
    pr_ref = values_for_keys(values, ["pr", "prRef", "pr_ref", "pullRequest", "pull_request"]) |> List.first()
    url = values_for_keys(values, ["url", "htmlUrl", "html_url"]) |> Enum.find(&String.contains?(&1, "/pull/"))
    number = values_for_keys(values, ["number", "prNumber", "pr_number"]) |> Enum.find(&String.match?(&1, ~r/^\d+$/))

    cond do
      is_binary(pr_ref) and pr_ref != "" ->
        {:ok, %{ref: pr_ref, number: pr_number(pr_ref), url: url}}

      is_binary(url) and is_binary(number) ->
        {:ok, %{ref: url, number: number, url: url}}

      true ->
        :error
    end
  end

  defp pr_from_gh(%Issue{} = issue, workspace, branch, runner, worker_host) do
    args =
      ["pr", "view", "--json", "number,url,headRefName,headRepositoryOwner,headRepository"]
      |> maybe_add_branch_arg(issue, branch)

    case run_command(runner, "gh", args, cd: workspace, worker_host: worker_host) do
      {:ok, raw} ->
        with {:ok, payload} <- Jason.decode(raw),
             {:ok, pr} <- pr_from_gh_payload(payload) do
          {:ok, pr}
        else
          _ ->
            {:blocked, "could not parse GitHub PR metadata for In Review issue", %{branch: branch}}
        end

      {:error, reason} ->
        {:blocked, "In Review requires an existing GitHub pull request", %{branch: branch, error: inspect(reason)}}
    end
  end

  defp maybe_add_branch_arg(args, %Issue{branch_name: issue_branch}, branch) do
    if is_binary(issue_branch) and String.trim(issue_branch) != "" and String.trim(issue_branch) == branch do
      args ++ [branch]
    else
      args
    end
  end

  defp pr_from_gh_payload(%{"number" => number} = payload) do
    number = to_string(number)
    url = payload["url"]

    ref =
      cond do
        is_binary(url) and url != "" ->
          url

        owner_repo = owner_repo_from_payload(payload) ->
          owner_repo <> "#" <> number

        true ->
          nil
      end

    if is_binary(ref) do
      {:ok, %{ref: ref, number: number, url: url}}
    else
      :error
    end
  end

  defp pr_from_gh_payload(_payload), do: :error

  defp owner_repo_from_payload(payload) do
    with owner when is_binary(owner) <- owner_login(payload["headRepositoryOwner"]),
         repo when is_binary(repo) <- repo_name(payload["headRepository"]) do
      owner <> "/" <> repo
    else
      _ -> nil
    end
  end

  defp owner_login(%{"login" => login}) when is_binary(login), do: login
  defp owner_login(login) when is_binary(login), do: login
  defp owner_login(_owner), do: nil

  defp repo_name(%{"name" => name}) when is_binary(name), do: name
  defp repo_name(name) when is_binary(name), do: name
  defp repo_name(_repo), do: nil

  defp prloop_status(workspace, branch, pr_ref, runner, worker_host) do
    args = [
      "status",
      "--config",
      Path.join(workspace, ".cloud-review-loop.json"),
      "--pr",
      pr_ref,
      "--worktree",
      workspace,
      "--branch",
      branch,
      "--json"
    ]

    case run_command(runner, "prloop", args, cd: workspace, worker_host: worker_host) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, status} ->
            {:ok, status}

          {:error, reason} ->
            {:blocked, "prloop status returned invalid JSON for In Review issue", %{branch: branch, pr: pr_ref, error: inspect(reason)}}
        end

      {:error, reason} ->
        {:blocked, "prloop status failed for In Review issue", %{branch: branch, pr: pr_ref, error: inspect(reason)}}
    end
  end

  defp handle_status(issue, workspace, branch, pr, %{} = status, runner, worker_host) do
    run = Map.get(status, "run", %{})
    state = normalized_status_value(run["state"])
    action = normalized_status_value(run["recommendedAction"])
    resumable? = run["resumable"] == true
    evidence = status_evidence(status)

    case status_recommendation(state, action, resumable?) do
      :clean ->
        clean_issue(issue)

      :blocked ->
        block_issue(issue, "prloop requires manual reconciliation (state=#{state}, action=#{action})", evidence)

      {:tmux, "run"} ->
        ensure_tmux(issue, workspace, branch, pr, "run", runner, worker_host, evidence)

      {:tmux, "resume"} ->
        ensure_tmux(issue, workspace, branch, pr, "resume", runner, worker_host, evidence)

      :waiting ->
        Logger.info("Review monitor is waiting for #{issue_context(issue)} state=#{state} action=#{action} evidence=#{inspect(evidence)}")
        :waiting
    end
  end

  defp status_recommendation(state, action, resumable?) do
    case {clean_status?(state, action), blocked_status?(state, action, resumable?)} do
      {true, _blocked?} ->
        :clean

      {_clean?, true} ->
        :blocked

      {_clean?, _blocked?} ->
        tmux_status_recommendation(action, resumable?)
    end
  end

  defp clean_status?(state, action), do: state == "succeeded" or action == "done"

  defp blocked_status?(state, action, resumable?) do
    MapSet.member?(@blocked_actions, action) or failed_terminal_status?(state, resumable?)
  end

  defp failed_terminal_status?(_state, true), do: false
  defp failed_terminal_status?(state, false), do: MapSet.member?(@failure_states, state)

  defp tmux_status_recommendation("start", _resumable?), do: {:tmux, "run"}
  defp tmux_status_recommendation(_action, true), do: {:tmux, "resume"}

  defp tmux_status_recommendation(action, false) do
    if MapSet.member?(@resumable_actions, action), do: {:tmux, "resume"}, else: :waiting
  end

  defp clean_issue(%Issue{id: issue_id} = issue) do
    clean_state = Config.settings!().review_monitor.clean_state

    case Tracker.update_issue_state(issue_id, clean_state) do
      :ok ->
        Logger.info("Review monitor moved #{issue_context(issue)} to #{clean_state}")
        :clean

      {:error, reason} ->
        {:error, {:state_update_failed, clean_state, reason}}
    end
  end

  defp block_issue(%Issue{id: issue_id} = issue, reason, evidence) do
    blocked_state = Config.settings!().review_monitor.blocked_state
    comment = blocked_comment(reason, evidence)

    with :ok <- Tracker.create_comment(issue_id, comment),
         :ok <- Tracker.update_issue_state(issue_id, blocked_state) do
      Logger.warning("Review monitor moved #{issue_context(issue)} to #{blocked_state}: #{reason}")
      {:blocked, reason}
    else
      {:error, error} -> {:error, {:block_issue_failed, blocked_state, reason, error}}
    end
  end

  defp ensure_tmux(issue, workspace, branch, pr, prloop_command, runner, worker_host, evidence) do
    session = tmux_session_name(issue, pr)

    tmux_context = %{
      issue: issue,
      workspace: workspace,
      branch: branch,
      pr: pr,
      prloop_command: prloop_command,
      runner: runner,
      worker_host: worker_host,
      evidence: evidence,
      session: session
    }

    case run_command(runner, "tmux", ["has-session", "-t", session], cd: workspace, worker_host: worker_host) do
      {:ok, _output} ->
        Logger.info("Review monitor found existing prloop tmux session for #{issue_context(issue)} session=#{session}")
        :waiting

      {:error, _reason} ->
        start_tmux(tmux_context)
    end
  end

  defp start_tmux(%{
         issue: issue,
         workspace: workspace,
         branch: branch,
         pr: pr,
         prloop_command: prloop_command,
         session: session,
         runner: runner,
         worker_host: worker_host,
         evidence: evidence
       }) do
    log_dir = evidence[:log_dir] || git_log_dir(workspace, runner, worker_host)
    command = prloop_shell_command(prloop_command, workspace, branch, pr.ref, session, log_dir)

    case run_command(runner, "tmux", ["new-session", "-d", "-s", session, "-c", workspace, command],
           cd: workspace,
           worker_host: worker_host
         ) do
      {:ok, _output} ->
        Logger.info("Review monitor started prloop #{prloop_command} for #{issue_context(issue)} session=#{session}")
        :resumed

      {:error, reason} ->
        block_issue(
          issue,
          "could not start detached prloop #{prloop_command} session",
          Map.merge(evidence, %{
            branch: branch,
            pr: pr.ref,
            session: session,
            error: inspect(reason)
          })
        )
    end
  end

  defp git_log_dir(workspace, runner, worker_host) do
    case run_command(runner, "git", ["rev-parse", "--git-path", "cloud-review-loop/tmux"],
           cd: workspace,
           worker_host: worker_host
         ) do
      {:ok, path} -> String.trim(path)
      {:error, _reason} -> Path.join(workspace, ".git/cloud-review-loop/tmux")
    end
  end

  defp prloop_shell_command(prloop_command, workspace, branch, pr_ref, session, log_dir) do
    log_path = Path.join(log_dir, session <> ".log")

    [
      "mkdir -p #{shell_escape(log_dir)}",
      "prloop #{prloop_command}",
      "--config #{shell_escape(Path.join(workspace, ".cloud-review-loop.json"))}",
      "--pr #{shell_escape(pr_ref)}",
      "--worktree #{shell_escape(workspace)}",
      "--branch #{shell_escape(branch)}",
      "--json",
      "> #{shell_escape(log_path)} 2>&1; printf '\\nexit=%s\\n' $? >> #{shell_escape(log_path)}"
    ]
    |> Enum.join(" ")
  end

  defp tmux_session_name(%Issue{identifier: identifier}, %{number: number}) do
    issue_part =
      case identifier do
        value when is_binary(value) and value != "" -> "doc-" <> String.downcase(value)
        _ -> nil
      end

    ["prloop", issue_part, "pr", to_string(number)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("-")
  end

  defp status_evidence(status) do
    %{
      state_path: status["statePath"] || get_in(status, ["run", "statePath"]),
      log_dir: status["logDir"] || get_in(status, ["run", "logDir"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp blocked_comment(reason, evidence) do
    details =
      Enum.map_join(evidence, "\n", fn {key, value} -> "- #{key}: `#{value}`" end)

    base = "## Symphony Review Monitor\n\nMoved this issue to Human Review.\n\nReason: #{reason}"

    if details == "" do
      base
    else
      base <> "\n\nEvidence:\n" <> details
    end
  end

  defp run_command(runner, command, args, opts) do
    cond do
      is_function(runner, 3) -> runner.(command, args, opts)
      is_atom(runner) -> runner.run(command, args, opts)
    end
  end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:worker_runtime_info, issue_id, %{worker_host: worker_host, workspace_path: workspace}})
    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_monitor_result(recipient, %Issue{id: issue_id}, outcome)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:review_monitor_result, issue_id, outcome})
    :ok
  end

  defp send_monitor_result(_recipient, _issue, _outcome), do: :ok

  defp flattened_values(value), do: flattened_values(value, [])

  defp flattened_values(%{} = map, acc) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      flattened_values(value, [{to_string(key), value} | acc])
    end)
  end

  defp flattened_values(values, acc) when is_list(values) do
    Enum.reduce(values, acc, &flattened_values(&1, &2))
  end

  defp flattened_values(_value, acc), do: acc

  defp values_for_keys(values, keys) do
    key_set = MapSet.new(keys)

    values
    |> Enum.flat_map(fn
      {key, value} when is_binary(value) ->
        if MapSet.member?(key_set, key), do: [value], else: []

      {key, value} when is_integer(value) ->
        if MapSet.member?(key_set, key), do: [Integer.to_string(value)], else: []

      _ ->
        []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_status_value(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalized_status_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalized_status_value()
  defp normalized_status_value(_value), do: ""

  defp pr_number(ref) when is_binary(ref) do
    case Regex.run(~r/(?:#|\/pull\/)(\d+)/, ref, capture: :all_but_first) do
      [number] -> number
      _ -> nil
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
