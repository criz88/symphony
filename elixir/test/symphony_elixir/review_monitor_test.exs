defmodule SymphonyElixir.ReviewMonitorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewMonitor

  test "clean prloop status moves issue to configured clean state" do
    issue = review_issue()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_review_monitor_workflow!()

    runner =
      runner(%{
        {"prloop", "status"} =>
          Jason.encode!(%{
            "run" => %{"state" => "succeeded", "recommendedAction" => "done", "resumable" => false},
            "statePath" => "/tmp/state.json",
            "logDir" => "/tmp/logs"
          })
      })

    assert :ok = ReviewMonitor.run(issue, self(), workspace: "/tmp/worktree", command_runner: runner)
    assert_receive {:memory_tracker_state_update, "issue-review", "Merging"}
    refute_received {:memory_tracker_comment, "issue-review", _body}
  end

  test "resumable prloop status starts one tmux resume session and leaves issue in review" do
    issue = review_issue()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_review_monitor_workflow!()

    runner =
      runner(%{
        {"prloop", "status"} =>
          Jason.encode!(%{
            "run" => %{"state" => "running", "recommendedAction" => "resume", "resumable" => true},
            "statePath" => "/tmp/state.json",
            "logDir" => "/tmp/logs"
          }),
        {"tmux", "has-session"} => {:error, {:exit_status, 1, ""}},
        {"tmux", "new-session"} => ""
      })

    assert :ok = ReviewMonitor.run(issue, self(), workspace: "/tmp/worktree", command_runner: runner)
    assert_receive {:review_monitor_result, "issue-review", :resumed}
    assert_received {:review_monitor_command, "tmux", ["new-session", "-d", "-s", "prloop-doc-doc-123-pr-42" | _]}
    refute_received {:memory_tracker_state_update, "issue-review", _state}
  end

  test "waiting prloop status with existing tmux session does not start a duplicate session" do
    issue = review_issue()
    write_review_monitor_workflow!()

    runner =
      runner(%{
        {"prloop", "status"} =>
          Jason.encode!(%{
            "run" => %{"state" => "running", "recommendedAction" => "wait_for_review", "resumable" => true},
            "statePath" => "/tmp/state.json",
            "logDir" => "/tmp/logs"
          }),
        {"tmux", "has-session"} => ""
      })

    assert :ok = ReviewMonitor.run(issue, self(), workspace: "/tmp/worktree", command_runner: runner)
    assert_receive {:review_monitor_result, "issue-review", :waiting}
    refute_received {:review_monitor_command, "tmux", ["new-session" | _]}
  end

  test "missing pull request moves issue to configured blocked state with a comment" do
    issue = review_issue()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_review_monitor_workflow!()

    runner =
      runner(%{
        {"gh", "pr"} => {:error, {:exit_status, 1, "no pull request found"}}
      })

    assert :ok = ReviewMonitor.run(issue, self(), workspace: "/tmp/worktree", command_runner: runner)
    assert_receive {:memory_tracker_comment, "issue-review", body}
    assert body =~ "In Review requires an existing GitHub pull request"
    assert_receive {:memory_tracker_state_update, "issue-review", "Human Review"}
  end

  test "manual reconciliation status moves issue to configured blocked state with evidence" do
    issue = review_issue()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_review_monitor_workflow!()

    runner =
      runner(%{
        {"prloop", "status"} =>
          Jason.encode!(%{
            "run" => %{"state" => "failed", "recommendedAction" => "manual_reconcile", "resumable" => false},
            "statePath" => "/tmp/state.json",
            "logDir" => "/tmp/logs"
          })
      })

    assert :ok = ReviewMonitor.run(issue, self(), workspace: "/tmp/worktree", command_runner: runner)
    assert_receive {:memory_tracker_comment, "issue-review", body}
    assert body =~ "manual reconciliation"
    assert body =~ "/tmp/state.json"
    assert body =~ "/tmp/logs"
    assert_receive {:memory_tracker_state_update, "issue-review", "Human Review"}
  end

  defp write_review_monitor_workflow! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_monitor_enabled: true,
      review_monitor_states: ["In Review"],
      review_monitor_clean_state: "Merging",
      review_monitor_blocked_state: "Human Review"
    )
  end

  defp review_issue do
    %Issue{
      id: "issue-review",
      identifier: "DOC-123",
      title: "Review this PR",
      state: "In Review",
      branch_name: "feature/doc-123",
      assigned_to_worker: true
    }
  end

  defp runner(overrides) do
    parent = self()

    fn command, args, _opts ->
      send(parent, {:review_monitor_command, command, args})

      case response_for(command, args, overrides) do
        {:error, _reason} = error -> error
        output when is_binary(output) -> {:ok, output}
      end
    end
  end

  defp response_for("git", ["branch", "--show-current"], _overrides), do: "feature/doc-123\n"
  defp response_for("git", ["rev-parse", "--git-dir"], _overrides), do: ".git\n"
  defp response_for("git", ["rev-parse", "--git-path", "cloud-review-loop/tmux"], _overrides), do: "/tmp/logs\n"
  defp response_for("sh", ["-lc", _script], _overrides), do: ""

  defp response_for("gh", ["pr" | _args], overrides) do
    Map.get(overrides, {"gh", "pr"}, Jason.encode!(%{"number" => 42, "url" => "https://github.com/acme/repo/pull/42"}))
  end

  defp response_for("prloop", ["status" | _args], overrides), do: Map.fetch!(overrides, {"prloop", "status"})
  defp response_for("tmux", ["has-session" | _args], overrides), do: Map.get(overrides, {"tmux", "has-session"}, "")
  defp response_for("tmux", ["new-session" | _args], overrides), do: Map.get(overrides, {"tmux", "new-session"}, "")
end
