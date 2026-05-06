defmodule SymphonyElixir.Evidence do
  @moduledoc """
  File-backed runtime evidence writer for Symphony issue runs.
  """

  alias SymphonyElixir.LogFile

  @schema_version 1
  @default_excerpt_chars 2_048

  @join_keys [
    :schema_version,
    :captured_at,
    :source,
    :issue_id,
    :issue_identifier,
    :run_id,
    :session_id,
    :thread_id,
    :turn_id,
    :thread_parse_status,
    :turn_parse_status,
    :codex_session_source_path,
    :codex_session_path_parse_status,
    :codex_session_copy_status,
    :workspace_path,
    :worker_host,
    :branch,
    :commit,
    :pr_url,
    :pr_number,
    :workpad_comment_id,
    :prloop_state_path,
    :prloop_log_dir
  ]

  @event_categories MapSet.new([
                      "session_started",
                      "session_completed",
                      "session_failed",
                      "command_failed",
                      "validation_started",
                      "validation_passed",
                      "validation_failed",
                      "pr_opened",
                      "pr_updated",
                      "ci_check_completed",
                      "review_comment_seen",
                      "review_feedback_fixed",
                      "prloop_started",
                      "prloop_waiting",
                      "prloop_clean",
                      "prloop_blocked",
                      "linear_state_changed",
                      "human_review_blocker_recorded",
                      "follow_up_created",
                      "workspace_cleanup_preflight",
                      "workspace_cleanup_completed",
                      "evidence_capture_failed"
                    ])

  @trust_levels MapSet.new(["machine_captured", "external_source", "agent_authored"])

  @type evidence_context :: map()

  @spec logs_root(keyword()) :: Path.t()
  def logs_root(opts \\ []) do
    cond do
      is_binary(Keyword.get(opts, :logs_root)) ->
        Path.expand(Keyword.fetch!(opts, :logs_root))

      is_binary(Application.get_env(:symphony_elixir, :logs_root)) ->
        Path.expand(Application.fetch_env!(:symphony_elixir, :logs_root))

      is_binary(System.get_env("SYMPHONY_LOGS_ROOT")) ->
        Path.expand(System.fetch_env!("SYMPHONY_LOGS_ROOT"))

      true ->
        default_logs_root_from_log_file()
    end
  end

  @spec evidence_root(keyword()) :: Path.t()
  def evidence_root(opts \\ []) do
    Path.join(logs_root(opts), "evidence")
  end

  @spec session_dir(map(), keyword()) :: Path.t()
  def session_dir(context, opts \\ []) when is_map(context) do
    context = normalize_context(context)

    Path.join([
      evidence_root(opts),
      "sessions",
      safe_path_part(context.issue_identifier || "unknown-issue"),
      safe_path_part(context.run_id || "unknown-run")
    ])
  end

  @spec init_manifest(map(), keyword()) :: {:ok, evidence_context()} | {:error, term()}
  def init_manifest(context, opts \\ []) when is_map(context) do
    context = normalize_context(context)
    dir = session_dir(context, opts)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir_p(Path.join(dir, "prloop/logs")),
         :ok <- write_json_file(Path.join(dir, "manifest.json"), manifest_payload(context)) do
      {:ok, Map.put(context, :session_dir, dir)}
    end
  end

  @spec update_manifest(map(), map(), keyword()) :: {:ok, evidence_context()} | {:error, term()}
  def update_manifest(context, attrs, opts \\ []) when is_map(context) and is_map(attrs) do
    with {:ok, context} <- ensure_session(context, opts),
         {:ok, manifest} <- read_json_file(Path.join(context.session_dir, "manifest.json")),
         :ok <-
           write_json_file(
             Path.join(context.session_dir, "manifest.json"),
             deep_merge(manifest, stringify_keys(attrs))
           ) do
      {:ok, context}
    end
  end

  @spec append_event(map(), String.t() | atom(), map(), keyword()) ::
          {:ok, evidence_context()} | {:error, term()}
  def append_event(context, category, attrs \\ %{}, opts \\ []) when is_map(context) and is_map(attrs) do
    category = to_string(category)

    with :ok <- validate_event_category(category),
         {:ok, context} <- ensure_session(context, opts) do
      event = event_payload(context, category, attrs)
      redaction_status = Map.get(event, "redaction_status", "not_needed")

      with :ok <- append_jsonl(Path.join(context.session_dir, "events.jsonl"), event),
           {:ok, context} <- mark_artifact_captured(context, :events, "events.jsonl", "symphony", %{}, opts) do
        maybe_mark_redacted(context, redaction_status, opts)
      end
    end
  end

  @spec write_validation_summary(map(), map(), keyword()) ::
          {:ok, evidence_context()} | {:error, term()}
  def write_validation_summary(context, summary, opts \\ []) when is_map(context) and is_map(summary) do
    with {:ok, context} <- ensure_session(context, opts) do
      {command, command_redaction} = redact(value(summary, :command))
      {stdout_excerpt, stdout_redaction} = scrub_excerpt(value(summary, :stdout) || value(summary, :stdout_excerpt))
      {stderr_excerpt, stderr_redaction} = scrub_excerpt(value(summary, :stderr) || value(summary, :stderr_excerpt))
      redaction_status = combine_redaction_status([command_redaction, stdout_redaction, stderr_redaction])

      entry =
        context
        |> join_payload("symphony")
        |> Map.merge(%{
          "command" => blank_to_nil(command),
          "started_at" => value(summary, :started_at),
          "ended_at" => value(summary, :ended_at),
          "duration_ms" => value(summary, :duration_ms) || value(summary, :elapsed_ms),
          "exit_code" => value(summary, :exit_code),
          "stdout_excerpt" => stdout_excerpt,
          "stderr_excerpt" => stderr_excerpt,
          "trust_level" => normalize_trust_level(value(summary, :trust_level), "machine_captured"),
          "redaction_status" => redaction_status
        })

      with :ok <- append_jsonl(Path.join(context.session_dir, "validation.jsonl"), entry),
           {:ok, context} <-
             mark_artifact_captured(context, :validation, "validation.jsonl", "symphony", %{}, opts) do
        maybe_mark_redacted(context, redaction_status, opts)
      end
    end
  end

  @spec write_git_summary(map(), map(), keyword()) :: {:ok, evidence_context()} | {:error, term()}
  def write_git_summary(context, summary, opts \\ []) when is_map(context) and is_map(summary) do
    context =
      context
      |> maybe_put_context(:branch, value(summary, :branch))
      |> maybe_put_context(:commit, value(summary, :commit))

    with {:ok, context} <- ensure_session(context, opts) do
      entry =
        context
        |> join_payload("git")
        |> Map.merge(stringify_keys(summary))
        |> Map.put_new("trust_level", "machine_captured")

      with :ok <- write_json_file(Path.join(context.session_dir, "git.json"), entry) do
        update_manifest(
          context,
          %{
            branch: value(summary, :branch),
            commit: value(summary, :commit),
            artifact_paths: %{git: "git.json"},
            artifacts: %{git: artifact_status("captured", "git", nil, "git.json")}
          },
          opts
        )
      end
    end
  end

  @spec capture_session_started(map(), map(), keyword()) ::
          {:ok, evidence_context()} | {:error, term()}
  def capture_session_started(context, attrs, opts \\ []) when is_map(context) and is_map(attrs) do
    context =
      context
      |> merge_context_attrs(attrs)
      |> Map.put(:source, "codex_app_server")
      |> normalize_context()

    with {:ok, context} <- ensure_session(context, opts),
         :ok <- maybe_write_workspace_git_summary(context, opts),
         {:ok, context} <- maybe_write_linear_summary(context, attrs, opts),
         {:ok, context} <- capture_codex_session_artifact(context, attrs, opts),
         {:ok, context} <-
           append_event(
             context,
             "session_started",
             %{
               evidence_ref: "manifest.json",
               summary: "Codex session started",
               trust_level: "machine_captured",
               codex_session_copy_status: value(context, :codex_session_copy_status),
               codex_session_source_path: value(context, :codex_session_source_path),
               thread_parse_status: value(context, :thread_parse_status),
               turn_parse_status: value(context, :turn_parse_status)
             },
             opts
           ) do
      update_manifest(
        context,
        %{
          outcome: "running",
          last_error: nil,
          session_id: context.session_id,
          thread_id: context.thread_id,
          turn_id: context.turn_id,
          thread_parse_status: context.thread_parse_status,
          turn_parse_status: context.turn_parse_status,
          codex_session_source_path: context.codex_session_source_path,
          codex_session_path_parse_status: context.codex_session_path_parse_status,
          codex_session_copy_status: context.codex_session_copy_status
        },
        opts
      )
    end
  end

  @spec capture_session_completed(map(), map(), keyword()) ::
          {:ok, evidence_context()} | {:error, term()}
  def capture_session_completed(context, attrs, opts \\ []) when is_map(context) and is_map(attrs) do
    context =
      context
      |> merge_context_attrs(attrs)
      |> normalize_context()

    with {:ok, context} <-
           append_event(
             context,
             "session_completed",
             %{
               evidence_ref: "manifest.json",
               summary: "Codex session completed",
               trust_level: "machine_captured"
             },
             opts
           ) do
      update_manifest(
        context,
        %{
          ended_at: now_iso8601(),
          outcome: "completed",
          last_error: nil,
          session_id: context.session_id,
          thread_id: context.thread_id,
          turn_id: context.turn_id
        },
        opts
      )
    end
  end

  @spec capture_session_failed(map(), map(), keyword()) ::
          {:ok, evidence_context()} | {:error, term()}
  def capture_session_failed(context, attrs, opts \\ []) when is_map(context) and is_map(attrs) do
    context =
      context
      |> merge_context_attrs(attrs)
      |> normalize_context()

    last_error = value(attrs, :last_error) || value(attrs, :reason)

    with {:ok, context} <-
           append_event(
             context,
             "session_failed",
             %{
               evidence_ref: "manifest.json",
               summary: "Codex session failed",
               trust_level: "machine_captured",
               last_error: inspect(last_error)
             },
             opts
           ) do
      update_manifest(
        context,
        %{
          ended_at: now_iso8601(),
          outcome: "failed",
          last_error: inspect(last_error),
          session_id: context.session_id,
          thread_id: context.thread_id,
          turn_id: context.turn_id
        },
        opts
      )
    end
  end

  @spec write_linear_summary(map(), map(), keyword()) :: {:ok, evidence_context()} | {:error, term()}
  def write_linear_summary(context, issue, opts \\ []) when is_map(context) and is_map(issue) do
    with {:ok, context} <- ensure_session(context, opts) do
      payload =
        context
        |> join_payload("linear")
        |> Map.merge(%{
          "issue" => linear_issue_summary(issue),
          "trust_level" => "machine_captured"
        })

      with :ok <- write_json_file(Path.join(context.session_dir, "linear.json"), payload) do
        update_manifest(
          context,
          %{
            artifact_paths: %{linear: "linear.json"},
            artifacts: %{linear: artifact_status("captured", "linear", nil, "linear.json")}
          },
          opts
        )
      end
    end
  end

  @spec git_summary(Path.t()) :: {:ok, map()} | {:error, term()}
  def git_summary(workspace) when is_binary(workspace) do
    with {:ok, _git_dir} <- run_git(workspace, ["rev-parse", "--git-dir"]) do
      branch = git_value(workspace, ["branch", "--show-current"])
      commit = git_value(workspace, ["rev-parse", "HEAD"])
      status_output = git_value(workspace, ["status", "--short"]) || ""
      status_lines = String.split(status_output, "\n", trim: true)
      upstream = git_value(workspace, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
      ahead_behind = if is_binary(upstream), do: git_value(workspace, ["rev-list", "--left-right", "--count", "@{u}...HEAD"])
      {behind, ahead} = parse_ahead_behind(ahead_behind)

      {:ok,
       %{
         branch: blank_to_nil(branch),
         commit: blank_to_nil(commit),
         status_summary: %{
           short: scrub_status_lines(status_lines),
           file_count: length(status_lines)
         },
         pushed: pushed_signal(ahead),
         unpushed_work: unpushed_signal(ahead),
         unpushed_commit_count: ahead,
         upstream: upstream,
         behind_upstream_commit_count: behind,
         uncommitted_work: status_lines != []
       }}
    end
  end

  @spec capture_workspace_cleanup_preflight(map(), Path.t(), keyword()) ::
          {:ok, evidence_context()} | {:error, term()}
  def capture_workspace_cleanup_preflight(context, workspace, opts \\ [])
      when is_map(context) and is_binary(workspace) do
    context =
      context
      |> Map.put(:workspace_path, workspace)
      |> normalize_context()

    case ensure_session(context, opts) do
      {:ok, context} ->
        do_capture_workspace_cleanup_preflight(context, workspace, opts)

      {:error, reason} ->
        risks = cleanup_risks(workspace, {:error, reason})
        maybe_block_risky_cleanup(context, reason, risks, opts)
    end
  end

  @spec capture_workspace_cleanup_completed(map(), Path.t(), keyword()) :: :ok | {:error, term()}
  def capture_workspace_cleanup_completed(context, workspace, opts \\ [])
      when is_map(context) and is_binary(workspace) do
    context =
      context
      |> Map.put(:workspace_path, workspace)
      |> normalize_context()

    with {:ok, context} <-
           append_event(
             context,
             "workspace_cleanup_completed",
             %{
               evidence_ref: "manifest.json",
               summary: "Workspace cleanup completed",
               trust_level: "machine_captured"
             },
             opts
           ),
         {:ok, _context} <-
           update_manifest(
             context,
             %{
               ended_at: now_iso8601(),
               outcome: "completed",
               last_error: nil
             },
             opts
           ) do
      :ok
    end
  end

  @spec redact(term()) :: {String.t(), String.t()}
  def redact(value) do
    text = to_text(value)

    replacements = [
      {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/is, "[REDACTED PRIVATE KEY]"},
      {~r/\bBearer\s+[A-Za-z0-9._~+\/=-]+/i, "Bearer [REDACTED]"},
      {~r/((?:Authorization)\s*:\s*)[^\r\n]+/i, "\\1[REDACTED]"},
      {~r/((?:Cookie|Set-Cookie)\s*:\s*)[^\r\n]+/i, "\\1[REDACTED]"},
      {~r{(https?://)([^/\s:@]+):([^@\s/]+)@}i, "\\1[REDACTED]@"},
      {~r/((?:api[_-]?key|token|secret|password|passwd|credential|access[_-]?key|refresh[_-]?token)\s*[:=]\s*)(["']?)[^\s"'&;]+/i, "\\1[REDACTED]"},
      {~r/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b/, "[REDACTED TOKEN]"},
      {~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, "[REDACTED JWT]"}
    ]

    redacted =
      Enum.reduce(replacements, text, fn {regex, replacement}, acc ->
        Regex.replace(regex, acc, replacement)
      end)

    {redacted, redaction_status(text, redacted)}
  end

  defp do_capture_workspace_cleanup_preflight(context, workspace, opts) do
    git_result = git_summary(workspace)
    risks = cleanup_risks(workspace, git_result)

    result =
      with :ok <- maybe_write_git_summary(context, git_result, opts),
           :ok <- harvest_prloop(context, workspace, opts),
           {:ok, _context} <-
             append_event(
               context,
               "workspace_cleanup_preflight",
               %{
                 evidence_ref: "manifest.json",
                 summary: "Workspace cleanup preflight captured",
                 trust_level: "machine_captured"
               },
               opts
             ) do
        :ok
      end

    case result do
      :ok ->
        {:ok, Map.put(context, :cleanup_risks, risks)}

      {:error, reason} ->
        maybe_block_risky_cleanup(context, reason, risks, opts)
    end
  end

  defp maybe_block_risky_cleanup(context, reason, risks, opts) do
    record_capture_failure(context, reason, risks, opts)

    if risky_cleanup?(risks) do
      {:error, {:evidence_capture_failed, reason, risks}}
    else
      {:ok, Map.merge(context, %{cleanup_risks: risks, evidence_capture_error: reason})}
    end
  end

  defp record_capture_failure(context, reason, risks, opts) do
    summary = "Evidence capture failed before workspace cleanup"

    _ =
      append_event(
        context,
        "evidence_capture_failed",
        %{
          evidence_ref: "manifest.json",
          summary: summary,
          trust_level: "machine_captured",
          last_error: inspect(reason),
          cleanup_risks: risks
        },
        opts
      )

    _ =
      update_manifest(
        context,
        %{
          ended_at: now_iso8601(),
          outcome: if(risky_cleanup?(risks), do: "blocked", else: "failed"),
          last_error: inspect(reason)
        },
        opts
      )

    :ok
  end

  defp maybe_write_git_summary(context, {:ok, summary}, opts) do
    case write_git_summary(context, summary, opts) do
      {:ok, _context} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_write_git_summary(_context, {:error, {:git_failed, _args, _status, _output}}, _opts) do
    :ok
  end

  defp maybe_write_git_summary(_context, {:error, _reason}, _opts), do: :ok

  defp maybe_write_workspace_git_summary(%{workspace_path: workspace} = context, opts)
       when is_binary(workspace) do
    maybe_write_git_summary(context, git_summary(workspace), opts)
  end

  defp maybe_write_workspace_git_summary(_context, _opts), do: :ok

  defp maybe_write_linear_summary(context, attrs, opts) do
    case value(attrs, :linear) || value(attrs, :issue) || value(context, :linear) do
      issue when is_map(issue) ->
        case write_linear_summary(context, issue, opts) do
          {:ok, _context} -> {:ok, context}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, context}
    end
  end

  defp capture_codex_session_artifact(context, attrs, opts) do
    source_path =
      value(attrs, :codex_session_source_path) ||
        value(context, :codex_session_source_path)

    context =
      context
      |> maybe_put_context(:codex_session_source_path, source_path)
      |> normalize_context()

    artifact = codex_session_artifact(context, source_path)
    attrs = codex_session_manifest_attrs(context, artifact)

    with {:ok, context} <- update_manifest(context, attrs, opts) do
      {:ok,
       context
       |> maybe_put_context(:codex_session_source_path, Map.get(artifact, :source_path))
       |> maybe_put_context(:codex_session_copy_status, artifact |> Map.get(:details, %{}) |> Map.get(:copy_status))
       |> normalize_context()}
    end
  end

  defp codex_session_artifact(_context, source_path)
       when not is_binary(source_path) or source_path == "" do
    %{
      status: "missing",
      path: nil,
      source: "codex",
      source_path: source_path,
      reason: "source_path_unavailable",
      details: %{
        copy_status: "not_attempted",
        risk: "codex_rollout_path_was_not_available_from_thread_payload"
      }
    }
  end

  defp codex_session_artifact(%{worker_host: worker_host}, source_path) when is_binary(worker_host) do
    %{
      status: "indexed",
      path: nil,
      source: "codex",
      source_path: source_path,
      reason: "remote_worker_source_not_copied",
      details: %{
        copy_status: "not_attempted",
        risk: "source_path_is_on_remote_worker_and_may_be_removed_before_later_harvest"
      }
    }
  end

  defp codex_session_artifact(context, source_path) when is_binary(source_path) do
    expanded_source = Path.expand(source_path)
    target = Path.join(context.session_dir, "codex-session.jsonl")

    cond do
      File.regular?(expanded_source) ->
        case File.cp(expanded_source, target) do
          :ok ->
            %{
              status: "captured",
              path: "codex-session.jsonl",
              source: "codex",
              source_path: expanded_source,
              reason: nil,
              details: %{copy_status: "copied", risk: nil}
            }

          {:error, reason} ->
            %{
              status: "indexed",
              path: nil,
              source: "codex",
              source_path: expanded_source,
              reason: "copy_failed",
              details: %{
                copy_status: "failed",
                error: inspect(reason),
                risk: "source_may_be_removed_before_later_harvest"
              }
            }
        end

      File.exists?(expanded_source) ->
        %{
          status: "indexed",
          path: nil,
          source: "codex",
          source_path: expanded_source,
          reason: "source_not_regular_file",
          details: %{
            copy_status: "not_attempted",
            risk: "source_path_was_not_a_regular_jsonl_file"
          }
        }

      true ->
        %{
          status: "indexed",
          path: nil,
          source: "codex",
          source_path: expanded_source,
          reason: "source_not_found",
          details: %{
            copy_status: "not_attempted",
            risk: "source_may_be_removed_before_later_harvest"
          }
        }
    end
  end

  defp codex_session_manifest_attrs(context, artifact) do
    copy_status = artifact |> Map.get(:details, %{}) |> Map.get(:copy_status)

    %{
      codex_session_source_path: Map.get(artifact, :source_path) || context.codex_session_source_path,
      codex_session_copy_status: copy_status,
      artifacts: %{codex_session: artifact_status(artifact)}
    }
    |> maybe_put_artifact_paths(:codex_session, artifact)
  end

  defp maybe_put_artifact_paths(attrs, key, %{status: "captured", path: path}) when is_binary(path) do
    Map.put(attrs, :artifact_paths, %{key => path})
  end

  defp maybe_put_artifact_paths(attrs, _key, _artifact), do: attrs

  defp harvest_prloop(context, workspace, opts) do
    prloop_root = Path.join([workspace, ".git", "cloud-review-loop"])

    if File.exists?(prloop_root) do
      destination = Path.join(context.session_dir, "prloop")

      with :ok <- File.mkdir_p(destination),
           metadata <- prloop_metadata(prloop_root),
           {:ok, log_artifact} <- copy_prloop_logs(prloop_root, destination, metadata),
           {:ok, state_artifact} <- copy_prloop_state(context, prloop_root, destination, metadata),
           {:ok, _context} <- update_prloop_manifest(context, state_artifact, log_artifact, opts) do
        :ok
      end
    else
      :ok
    end
  end

  defp copy_prloop_state(context, prloop_root, destination, metadata) do
    case select_prloop_state_source(context, prloop_root, metadata) do
      {:ok, source, discovery} ->
        with :ok <- copy_file(source, Path.join(destination, "state.json")) do
          {:ok,
           %{
             status: "captured",
             path: "prloop/state.json",
             source: "prloop",
             source_path: source,
             discovery: discovery
           }}
        end

      {:missing, reason, details} ->
        {:ok,
         %{
           status: "missing",
           path: nil,
           source: "prloop",
           reason: reason,
           details: details
         }}
    end
  end

  defp copy_prloop_logs(prloop_root, destination, metadata) do
    source = Path.join(prloop_root, "tmux")
    target = Path.join(destination, "logs")

    cond do
      File.dir?(source) ->
        with {:ok, _removed} <- File.rm_rf(target),
             {:ok, _copied} <- File.cp_r(source, target) do
          {:ok,
           %{
             status: "captured",
             path: "prloop/logs",
             source: "prloop",
             source_path: preferred_log_dir(metadata, prloop_root, source)
           }}
        else
          {:error, reason, file} -> {:error, {:prloop_logs_copy_failed, file, reason}}
          {:error, reason} -> {:error, {:prloop_logs_copy_failed, source, reason}}
        end

      File.exists?(source) ->
        {:error, {:prloop_logs_not_directory, source}}

      true ->
        {:ok,
         %{
           status: "not_applicable",
           path: nil,
           source: "prloop",
           reason: "prloop_logs_not_present"
         }}
    end
  end

  defp update_prloop_manifest(context, state_artifact, log_artifact, opts) do
    artifact_paths =
      %{}
      |> maybe_put_artifact_path(:prloop_state, state_artifact)
      |> maybe_put_artifact_path(:prloop_log_dir, log_artifact)

    attrs =
      %{
        artifact_paths: artifact_paths,
        artifacts: %{
          prloop_state: artifact_status(state_artifact),
          prloop_log_dir: artifact_status(log_artifact)
        }
      }
      |> maybe_put_context(:prloop_state_path, Map.get(state_artifact, :source_path))
      |> maybe_put_context(:prloop_log_dir, Map.get(log_artifact, :source_path))

    update_manifest(context, attrs, opts)
  end

  defp select_prloop_state_source(context, prloop_root, metadata) do
    candidates =
      []
      |> add_state_candidate(:context_prloop_state_path, value(context, :prloop_state_path), prloop_root)
      |> add_state_candidates(:log_state_path, Map.get(metadata, :state_paths, []), prloop_root)
      |> add_state_candidate(:legacy_flat_state, Path.join(prloop_root, "state.json"), prloop_root)

    case Enum.find(candidates, fn {_discovery, path} -> File.regular?(path) end) do
      {discovery, path} ->
        {:ok, path, Atom.to_string(discovery)}

      nil ->
        select_nested_prloop_state(prloop_root, candidates)
    end
  end

  defp add_state_candidates(candidates, discovery, paths, prloop_root) when is_list(paths) do
    Enum.reduce(paths, candidates, fn path, acc ->
      add_state_candidate(acc, discovery, path, prloop_root)
    end)
  end

  defp add_state_candidate(candidates, _discovery, nil, _prloop_root), do: candidates
  defp add_state_candidate(candidates, _discovery, "", _prloop_root), do: candidates

  defp add_state_candidate(candidates, discovery, path, prloop_root) when is_binary(path) do
    case normalize_prloop_path(path, prloop_root) do
      nil -> candidates
      normalized -> candidates ++ [{discovery, normalized}]
    end
  end

  defp select_nested_prloop_state(prloop_root, checked_candidates) do
    paths =
      prloop_root
      |> Path.join("state/*/state.json")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    case newest_unambiguous_path(paths) do
      {:ok, path} ->
        {:ok, path, "nested_state_search"}

      {:ambiguous, candidate_paths} ->
        {:missing, "ambiguous_prloop_state_candidates", %{candidate_paths: candidate_paths}}

      :none ->
        {:missing, "prloop_state_not_found", %{checked_paths: Enum.map(checked_candidates, &elem(&1, 1))}}
    end
  end

  defp newest_unambiguous_path([]), do: :none

  defp newest_unambiguous_path(paths) do
    candidates =
      paths
      |> Enum.flat_map(fn path ->
        case File.stat(path, time: :posix) do
          {:ok, stat} -> [{path, stat.mtime}]
          {:error, _reason} -> []
        end
      end)
      |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)

    case candidates do
      [] ->
        :none

      candidates ->
        select_newest_candidate(candidates)
    end
  end

  defp select_newest_candidate([{path, newest_mtime} | older] = candidates) do
    if Enum.any?(older, fn {_other_path, mtime} -> mtime == newest_mtime end) do
      {:ambiguous, Enum.map(candidates, &elem(&1, 0))}
    else
      {:ok, path}
    end
  end

  defp normalize_prloop_path(path, prloop_root) when is_binary(path) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, prloop_root)
      end

    prloop_root = Path.expand(prloop_root)

    if path_inside?(expanded, prloop_root), do: expanded
  end

  defp path_inside?(path, root) do
    relative = Path.relative_to(path, root)
    Path.type(relative) == :relative and relative != ".." and not String.starts_with?(relative, "../")
  end

  defp prloop_metadata(prloop_root) do
    log_root = Path.join(prloop_root, "tmux")

    if File.dir?(log_root) do
      log_root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reduce(%{state_paths: [], log_dirs: []}, &collect_prloop_metadata/2)
    else
      %{state_paths: [], log_dirs: []}
    end
  end

  defp collect_prloop_metadata(path, metadata) do
    case File.read(path) do
      {:ok, content} ->
        metadata
        |> append_metadata_values(:state_paths, extract_json_string_field(content, "statePath"))
        |> append_metadata_values(:state_paths, extract_json_string_field(content, "state_path"))
        |> append_metadata_values(:log_dirs, extract_json_string_field(content, "logDir"))
        |> append_metadata_values(:log_dirs, extract_json_string_field(content, "log_dir"))

      {:error, _reason} ->
        metadata
    end
  end

  defp append_metadata_values(metadata, key, values) do
    Map.update!(metadata, key, fn existing ->
      Enum.uniq(existing ++ values)
    end)
  end

  defp extract_json_string_field(content, field) do
    regex = Regex.compile!(~s/"#{Regex.escape(field)}"\\s*:\\s*("(?:[^"\\\\]|\\\\.)*")/)

    regex
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.flat_map(fn [encoded] ->
      case Jason.decode(encoded) do
        {:ok, value} when is_binary(value) -> [value]
        _other -> []
      end
    end)
  end

  defp preferred_log_dir(metadata, prloop_root, fallback) do
    metadata
    |> Map.get(:log_dirs, [])
    |> Enum.find_value(&normalize_prloop_path(&1, prloop_root))
    |> case do
      nil -> fallback
      path -> path
    end
  end

  defp mark_artifact_captured(context, name, path, source, metadata, opts) do
    update_manifest(
      context,
      %{
        artifact_paths: %{name => path},
        artifacts: %{name => artifact_status("captured", source, nil, path, metadata)}
      },
      opts
    )
  end

  defp maybe_put_artifact_path(paths, key, %{status: "captured", path: path}) when is_binary(path) do
    Map.put(paths, key, path)
  end

  defp maybe_put_artifact_path(paths, _key, _artifact), do: paths

  defp initial_artifact_statuses do
    %{
      events: artifact_status("missing", "symphony", "events_not_written_yet", "events.jsonl"),
      codex_session: artifact_status("not_applicable", "codex", "not_captured_by_cleanup_preflight", nil),
      validation: artifact_status("not_applicable", "symphony", "not_captured_by_cleanup_preflight", nil),
      git: artifact_status("missing", "git", "git_summary_not_captured_yet", "git.json"),
      pr: artifact_status("not_applicable", "github", "not_captured_by_cleanup_preflight", nil),
      ci: artifact_status("not_applicable", "ci", "not_captured_by_cleanup_preflight", nil),
      linear: artifact_status("not_applicable", "linear", "not_captured_by_cleanup_preflight", nil),
      prloop_state: artifact_status("not_applicable", "prloop", "prloop_not_harvested", nil),
      prloop_log_dir: artifact_status("not_applicable", "prloop", "prloop_not_harvested", nil)
    }
  end

  defp artifact_status(artifact) when is_map(artifact) do
    artifact_status(
      Map.fetch!(artifact, :status),
      Map.fetch!(artifact, :source),
      Map.get(artifact, :reason),
      Map.get(artifact, :path),
      %{
        source_path: Map.get(artifact, :source_path),
        discovery: Map.get(artifact, :discovery),
        details: Map.get(artifact, :details)
      }
    )
  end

  defp artifact_status(status, source, reason, path, metadata \\ %{}) do
    %{
      status: status,
      source: source,
      reason: reason,
      path: path,
      source_path: Map.get(metadata, :source_path),
      discovery: Map.get(metadata, :discovery),
      details: Map.get(metadata, :details)
    }
  end

  defp copy_file(source, target) do
    case File.cp(source, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_copy_failed, source, target, reason}}
    end
  end

  defp cleanup_risks(workspace, git_result) do
    git_summary =
      case git_result do
        {:ok, summary} -> summary
        _ -> %{}
      end

    git_unknown? = match?({:error, _reason}, git_result) and File.exists?(Path.join(workspace, ".git"))

    %{
      git_summary_failed: git_unknown?,
      uncommitted_work: value(git_summary, :uncommitted_work) == true,
      unpushed_work: value(git_summary, :unpushed_work) == true,
      prloop_evidence_under_workspace: File.exists?(Path.join([workspace, ".git", "cloud-review-loop"]))
    }
  end

  defp risky_cleanup?(risks) when is_map(risks) do
    Enum.any?(risks, fn {_key, value} -> value == true end)
  end

  defp default_logs_root_from_log_file do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())

    log_file
    |> Path.expand()
    |> Path.dirname()
    |> Path.dirname()
  end

  defp ensure_session(context, opts) do
    context = normalize_context(context)
    dir = session_dir(context, opts)
    manifest_path = Path.join(dir, "manifest.json")

    if File.regular?(manifest_path) do
      {:ok, Map.put(context, :session_dir, dir)}
    else
      init_manifest(context, opts)
    end
  end

  defp manifest_payload(context) do
    %{
      schema_version: @schema_version,
      issue_identifier: context.issue_identifier,
      issue_id: context.issue_id,
      run_id: context.run_id,
      session_id: context.session_id,
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      thread_parse_status: context.thread_parse_status,
      turn_parse_status: context.turn_parse_status,
      codex_session_source_path: context.codex_session_source_path,
      codex_session_path_parse_status: context.codex_session_path_parse_status,
      codex_session_copy_status: context.codex_session_copy_status,
      workspace_path: context.workspace_path,
      worker_host: context.worker_host,
      branch: context.branch,
      commit: context.commit,
      pr_url: context.pr_url,
      pr_number: context.pr_number,
      workpad_comment_id: context.workpad_comment_id,
      started_at: context.captured_at,
      ended_at: nil,
      outcome: "running",
      artifact_paths: %{},
      artifacts: initial_artifact_statuses(),
      last_error: nil,
      redaction_status: "not_needed"
    }
    |> stringify_keys()
  end

  defp event_payload(context, category, attrs) do
    {summary, summary_redaction} = redact(value(attrs, :summary))
    {last_error, error_redaction} = redact(value(attrs, :last_error))
    redaction_status = combine_redaction_status([summary_redaction, error_redaction])

    context
    |> join_payload(value(attrs, :source) || context.source || "symphony")
    |> Map.merge(%{
      "event_id" => value(attrs, :event_id) || event_id(category),
      "category" => category,
      "evidence_ref" => value(attrs, :evidence_ref),
      "summary" => blank_to_nil(summary),
      "trust_level" => normalize_trust_level(value(attrs, :trust_level), "machine_captured"),
      "last_error" => blank_to_nil(last_error),
      "redaction_status" => redaction_status
    })
    |> Map.merge(attrs |> Map.drop([:source, :event_id, :evidence_ref, :summary, :trust_level, :last_error]) |> stringify_keys())
  end

  defp join_payload(context, source) do
    context = normalize_context(Map.put(context, :source, source))

    @join_keys
    |> Map.new(fn key -> {Atom.to_string(key), value(context, key)} end)
    |> Map.put("schema_version", @schema_version)
    |> Map.put("captured_at", now_iso8601())
  end

  defp normalize_context(context) when is_map(context) do
    issue_identifier = value(context, :issue_identifier) || "unknown-issue"

    %{
      schema_version: @schema_version,
      captured_at: value(context, :captured_at) || now_iso8601(),
      source: value(context, :source) || "symphony",
      issue_id: value(context, :issue_id),
      issue_identifier: issue_identifier,
      run_id: value(context, :run_id) || default_run_id(issue_identifier),
      session_id: value(context, :session_id),
      thread_id: value(context, :thread_id),
      turn_id: value(context, :turn_id),
      thread_parse_status: value(context, :thread_parse_status),
      turn_parse_status: value(context, :turn_parse_status),
      codex_session_source_path: value(context, :codex_session_source_path),
      codex_session_path_parse_status: value(context, :codex_session_path_parse_status),
      codex_session_copy_status: value(context, :codex_session_copy_status),
      workspace_path: value(context, :workspace_path),
      worker_host: value(context, :worker_host),
      branch: value(context, :branch),
      commit: value(context, :commit),
      pr_url: value(context, :pr_url),
      pr_number: value(context, :pr_number),
      workpad_comment_id: value(context, :workpad_comment_id),
      prloop_state_path: value(context, :prloop_state_path),
      prloop_log_dir: value(context, :prloop_log_dir)
    }
    |> maybe_put_context(:session_dir, value(context, :session_dir))
  end

  defp validate_event_category(category) do
    if MapSet.member?(@event_categories, category) do
      :ok
    else
      {:error, {:unsupported_evidence_event_category, category}}
    end
  end

  defp maybe_mark_redacted(context, "redacted", opts) do
    update_manifest(context, %{redaction_status: "redacted"}, opts)
  end

  defp maybe_mark_redacted(context, _status, _opts), do: {:ok, context}

  defp append_jsonl(path, payload) do
    File.write(path, Jason.encode!(stringify_keys(payload)) <> "\n", [:append])
  end

  defp write_json_file(path, payload) do
    File.write(path, Jason.encode!(stringify_keys(payload), pretty: true) <> "\n")
  end

  defp read_json_file(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode(content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_git(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {scrubbed_output, _status} = scrub_excerpt(output)
        {:error, {:git_failed, args, status, scrubbed_output}}
    end
  end

  defp git_value(workspace, args) do
    case run_git(workspace, args) do
      {:ok, value} -> blank_to_nil(value)
      {:error, _reason} -> nil
    end
  end

  defp parse_ahead_behind(nil), do: {nil, nil}

  defp parse_ahead_behind(output) when is_binary(output) do
    case String.split(String.trim(output), ~r/\s+/, trim: true) do
      [behind, ahead] ->
        {parse_int(behind), parse_int(ahead)}

      _ ->
        {nil, nil}
    end
  end

  defp pushed_signal(ahead) when is_integer(ahead), do: ahead == 0
  defp pushed_signal(_ahead), do: nil

  defp unpushed_signal(ahead) when is_integer(ahead), do: ahead > 0
  defp unpushed_signal(_ahead), do: nil

  defp scrub_status_lines(lines) when is_list(lines) do
    lines
    |> Enum.take(50)
    |> Enum.map(fn line ->
      {scrubbed, _status} = scrub_excerpt(line, 300)
      scrubbed
    end)
  end

  defp scrub_excerpt(value, max_chars \\ @default_excerpt_chars) do
    value
    |> to_text()
    |> String.slice(0, max_chars)
    |> redact()
  end

  defp normalize_trust_level(level, fallback) when is_binary(level) do
    if MapSet.member?(@trust_levels, level), do: level, else: fallback
  end

  defp normalize_trust_level(_level, fallback), do: fallback

  defp combine_redaction_status(statuses) do
    if Enum.any?(statuses, &(&1 == "redacted")) do
      "redacted"
    else
      "not_needed"
    end
  end

  defp redaction_status(original, redacted) do
    if original == redacted, do: "not_needed", else: "redacted"
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp stringify_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {to_string(key), stringify_keys(nested_value)} end)
    |> Map.new()
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp linear_issue_summary(issue) when is_map(issue) do
    %{
      id: value(issue, :id),
      identifier: value(issue, :identifier),
      title: value(issue, :title),
      description: value(issue, :description),
      priority: value(issue, :priority),
      state: value(issue, :state),
      branch_name: value(issue, :branch_name),
      url: value(issue, :url),
      assignee_id: value(issue, :assignee_id),
      labels: value(issue, :labels) || [],
      blocked_by: value(issue, :blocked_by) || [],
      assigned_to_worker: value(issue, :assigned_to_worker),
      created_at: json_timestamp(value(issue, :created_at)),
      updated_at: json_timestamp(value(issue, :updated_at))
    }
  end

  defp json_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp json_timestamp(value), do: value

  defp merge_context_attrs(context, attrs) do
    Enum.reduce(
      [
        :issue_id,
        :issue_identifier,
        :run_id,
        :session_id,
        :thread_id,
        :turn_id,
        :thread_parse_status,
        :turn_parse_status,
        :codex_session_source_path,
        :codex_session_path_parse_status,
        :codex_session_copy_status,
        :workspace_path,
        :worker_host,
        :branch,
        :commit,
        :pr_url,
        :pr_number,
        :workpad_comment_id,
        :prloop_state_path,
        :prloop_log_dir
      ],
      context,
      fn key, acc ->
        maybe_put_context(acc, key, value(attrs, key))
      end
    )
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil

  defp maybe_put_context(context, _key, nil), do: context
  defp maybe_put_context(context, _key, ""), do: context
  defp maybe_put_context(context, key, value), do: Map.put(context, key, value)

  defp default_run_id(issue_identifier) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    unique = System.unique_integer([:positive, :monotonic])
    "#{safe_path_part(String.downcase(issue_identifier))}-#{timestamp}-#{unique}"
  end

  defp event_id(category) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    unique = System.unique_integer([:positive, :monotonic])
    "#{category}-#{timestamp}-#{unique}"
  end

  defp safe_path_part(value) when is_binary(value) do
    String.replace(value, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: inspect(value)

  defp parse_int(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
