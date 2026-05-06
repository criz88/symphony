defmodule SymphonyElixir.EvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Evidence

  test "manifest and events use configured logs root with explicit null join keys" do
    test_root = tmp_dir("evidence-layout")
    logs_root = Path.join(test_root, "logs")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      context = %{
        issue_identifier: "DOC-52",
        run_id: "run-1",
        workspace_path: "/tmp/docly-workspaces/DOC-52",
        branch: "feat/doc-52-agent-session-evidence-capture",
        commit: "abc123"
      }

      assert {:ok, evidence_context} = Evidence.init_manifest(context)

      session_dir = Path.join([logs_root, "evidence", "sessions", "DOC-52", "run-1"])
      assert evidence_context.session_dir == session_dir
      assert File.dir?(session_dir)

      manifest = read_json!(Path.join(session_dir, "manifest.json"))
      assert manifest["schema_version"] == 1
      assert manifest["issue_identifier"] == "DOC-52"
      assert Map.has_key?(manifest, "issue_id")
      assert manifest["issue_id"] == nil
      assert Map.has_key?(manifest, "workpad_comment_id")
      assert manifest["workpad_comment_id"] == nil
      assert manifest["artifact_paths"] == %{}
      assert manifest["artifacts"]["events"]["status"] == "missing"
      assert manifest["artifacts"]["events"]["path"] == "events.jsonl"
      assert manifest["artifacts"]["codex_session"]["status"] == "not_applicable"
      assert manifest["artifacts"]["validation"]["status"] == "not_applicable"
      assert manifest["artifacts"]["pr"]["status"] == "not_applicable"
      refute Map.has_key?(manifest["artifact_paths"], "codex_session")
      refute Map.has_key?(manifest["artifact_paths"], "validation")
      refute Map.has_key?(manifest["artifact_paths"], "pr")

      assert {:ok, _context} =
               Evidence.append_event(context, "session_started", %{
                 evidence_ref: "manifest.json",
                 summary: "Codex session started",
                 trust_level: "machine_captured"
               })

      [event] = read_jsonl!(Path.join(session_dir, "events.jsonl"))

      assert event["category"] == "session_started"
      assert event["event_id"] =~ "session_started-"
      assert event["issue_identifier"] == "DOC-52"
      assert event["issue_id"] == nil
      assert Map.has_key?(event, "session_id")
      assert event["session_id"] == nil
      assert event["pr_url"] == nil
      assert event["trust_level"] == "machine_captured"

      manifest = read_json!(Path.join(session_dir, "manifest.json"))
      assert manifest["artifact_paths"]["events"] == "events.jsonl"
      assert manifest["artifacts"]["events"]["status"] == "captured"
    after
      File.rm_rf(test_root)
    end
  end

  test "validation summaries redact sensitive-looking excerpts" do
    test_root = tmp_dir("evidence-redaction")
    logs_root = Path.join(test_root, "logs")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      context = %{issue_identifier: "DOC-52", run_id: "redaction-run"}

      private_key = """
      -----BEGIN PRIVATE KEY-----
      abcdefghijklmnop
      -----END PRIVATE KEY-----
      """

      sensitive_output = """
      Authorization: Bearer raw-bearer-token.abc123
      api_key=docly-secret-value
      Cookie: sessionid=raw-cookie-value
      password=super-secret-password
      ghp_1234567890abcdefghijklmnop
      #{private_key}
      """

      assert {:ok, _context} =
               Evidence.write_validation_summary(context, %{
                 command: "mix test --token=command-secret",
                 started_at: "2026-05-06T01:00:00Z",
                 ended_at: "2026-05-06T01:00:01Z",
                 duration_ms: 1_000,
                 exit_code: 1,
                 stdout: sensitive_output,
                 stderr: "token=stderr-secret"
               })

      session_dir = Path.join([logs_root, "evidence", "sessions", "DOC-52", "redaction-run"])
      validation = File.read!(Path.join(session_dir, "validation.jsonl"))

      refute validation =~ "raw-bearer-token"
      refute validation =~ "docly-secret-value"
      refute validation =~ "raw-cookie-value"
      refute validation =~ "super-secret-password"
      refute validation =~ "command-secret"
      refute validation =~ "stderr-secret"
      refute validation =~ "BEGIN PRIVATE KEY"
      refute validation =~ "ghp_1234567890"
      assert validation =~ "[REDACTED"

      manifest = read_json!(Path.join(session_dir, "manifest.json"))
      assert manifest["redaction_status"] == "redacted"
    after
      File.rm_rf(test_root)
    end
  end

  test "session lifecycle evidence copies rollout jsonl and writes linear summary" do
    test_root = tmp_dir("evidence-session-lifecycle")
    logs_root = Path.join(test_root, "logs")
    rollout_path = Path.join(test_root, "rollout-2026-05-06.jsonl")
    workspace = Path.join(test_root, "workspace")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      File.mkdir_p!(workspace)
      File.write!(rollout_path, ~s({"type":"session","id":"thread-55"}\n))

      context = %{
        issue_id: "issue-55",
        issue_identifier: "DOC-55",
        run_id: "session-run",
        session_id: "thread-55-turn-1",
        thread_id: "thread-55",
        turn_id: "turn-1",
        thread_parse_status: "parsed",
        turn_parse_status: "parsed",
        codex_session_source_path: rollout_path,
        codex_session_path_parse_status: "parsed",
        workspace_path: workspace
      }

      issue = %{
        id: "issue-55",
        identifier: "DOC-55",
        title: "Capture lifecycle evidence",
        state: "In Progress",
        branch_name: "feat/doc-55-session-evidence-lifecycle",
        url: "https://linear.app/criz/issue/DOC-55",
        labels: ["area-symphony"]
      }

      assert {:ok, evidence_context} =
               Evidence.capture_session_started(context, %{linear: issue})

      assert {:ok, _evidence_context} =
               Evidence.capture_session_completed(evidence_context, %{})

      session_dir = Path.join([logs_root, "evidence", "sessions", "DOC-55", "session-run"])

      assert File.read!(Path.join(session_dir, "codex-session.jsonl")) =~ "thread-55"

      linear = read_json!(Path.join(session_dir, "linear.json"))
      assert linear["issue"]["id"] == "issue-55"
      assert linear["issue"]["identifier"] == "DOC-55"
      assert linear["issue"]["state"] == "In Progress"

      manifest = read_json!(Path.join(session_dir, "manifest.json"))
      assert manifest["session_id"] == "thread-55-turn-1"
      assert manifest["thread_id"] == "thread-55"
      assert manifest["turn_id"] == "turn-1"
      assert manifest["thread_parse_status"] == "parsed"
      assert manifest["turn_parse_status"] == "parsed"
      assert manifest["artifact_paths"]["codex_session"] == "codex-session.jsonl"
      assert manifest["artifact_paths"]["linear"] == "linear.json"
      assert manifest["artifacts"]["codex_session"]["status"] == "captured"
      assert manifest["artifacts"]["codex_session"]["source_path"] == rollout_path
      assert manifest["artifacts"]["codex_session"]["details"]["copy_status"] == "copied"
      assert manifest["codex_session_copy_status"] == "copied"
      assert manifest["outcome"] == "completed"

      categories =
        session_dir
        |> Path.join("events.jsonl")
        |> read_jsonl!()
        |> Enum.map(& &1["category"])

      assert "session_started" in categories
      assert "session_completed" in categories
    after
      File.rm_rf(test_root)
    end
  end

  test "session lifecycle evidence indexes missing rollout source with copy risk" do
    test_root = tmp_dir("evidence-session-index")
    logs_root = Path.join(test_root, "logs")
    missing_rollout_path = Path.join(test_root, "missing-rollout.jsonl")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      context = %{
        issue_identifier: "DOC-55",
        run_id: "indexed-run",
        session_id: "thread-55-turn-2",
        thread_id: "thread-55",
        turn_id: "turn-2",
        codex_session_source_path: missing_rollout_path
      }

      assert {:ok, _evidence_context} =
               Evidence.capture_session_started(context, %{linear: %{identifier: "DOC-55"}})

      manifest = read_json!(Path.join([logs_root, "evidence", "sessions", "DOC-55", "indexed-run", "manifest.json"]))

      refute Map.has_key?(manifest["artifact_paths"], "codex_session")
      assert manifest["artifacts"]["codex_session"]["status"] == "indexed"
      assert manifest["artifacts"]["codex_session"]["reason"] == "source_not_found"
      assert manifest["artifacts"]["codex_session"]["details"]["copy_status"] == "not_attempted"
      assert manifest["artifacts"]["codex_session"]["details"]["risk"] =~ "source_may_be_removed"
    after
      File.rm_rf(test_root)
    end
  end

  test "cleanup preflight writes git summary and preserves DOC-18 shaped prloop artifacts" do
    test_root = tmp_dir("evidence-cleanup-preflight")
    logs_root = Path.join(test_root, "logs")
    workspace = Path.join(test_root, "workspace")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      create_git_workspace!(workspace)
      File.write!(Path.join(workspace, "uncommitted.txt"), "local work\n")

      prloop_root = Path.join([workspace, ".git", "cloud-review-loop"])
      state_path = Path.join([prloop_root, "state", "run-123", "state.json"])
      log_dir = Path.join(prloop_root, "tmux")
      File.mkdir_p!(Path.dirname(state_path))
      File.mkdir_p!(log_dir)
      File.write!(state_path, ~s({"state":"succeeded","runId":"run-123"}))

      File.write!(
        Path.join(log_dir, "prloop-doc-doc-18-pr-27.log"),
        Jason.encode!(%{"statePath" => state_path, "logDir" => log_dir}) <> "\nreview loop log\n"
      )

      context = %{
        issue_id: "issue-52",
        issue_identifier: "DOC-52",
        run_id: "cleanup-run",
        workspace_path: workspace
      }

      assert {:ok, evidence_context} = Evidence.capture_workspace_cleanup_preflight(context, workspace)
      assert :ok = Evidence.capture_workspace_cleanup_completed(evidence_context, workspace)

      session_dir = Path.join([logs_root, "evidence", "sessions", "DOC-52", "cleanup-run"])
      git = read_json!(Path.join(session_dir, "git.json"))

      assert git["issue_id"] == "issue-52"
      assert git["branch"] == "main"
      assert is_binary(git["commit"])
      assert git["uncommitted_work"] == true
      assert git["status_summary"]["file_count"] == 1

      assert File.read!(Path.join([session_dir, "prloop", "state.json"])) =~ "succeeded"

      assert File.read!(Path.join([session_dir, "prloop", "logs", "prloop-doc-doc-18-pr-27.log"])) =~
               "statePath"

      manifest = read_json!(Path.join(session_dir, "manifest.json"))
      assert manifest["artifact_paths"]["events"] == "events.jsonl"
      assert manifest["artifact_paths"]["git"] == "git.json"
      assert manifest["artifact_paths"]["prloop_state"] == "prloop/state.json"
      assert manifest["artifact_paths"]["prloop_log_dir"] == "prloop/logs"
      refute Map.has_key?(manifest["artifact_paths"], "codex_session")
      refute Map.has_key?(manifest["artifact_paths"], "validation")
      refute Map.has_key?(manifest["artifact_paths"], "pr")
      refute Map.has_key?(manifest["artifact_paths"], "ci")
      refute Map.has_key?(manifest["artifact_paths"], "linear")

      assert manifest["artifacts"]["prloop_state"]["status"] == "captured"
      assert manifest["artifacts"]["prloop_state"]["path"] == "prloop/state.json"
      assert manifest["artifacts"]["prloop_state"]["source_path"] == state_path
      assert manifest["artifacts"]["prloop_state"]["discovery"] == "log_state_path"
      assert manifest["artifacts"]["prloop_log_dir"]["status"] == "captured"
      assert manifest["artifacts"]["prloop_log_dir"]["path"] == "prloop/logs"
      assert manifest["artifacts"]["prloop_log_dir"]["source_path"] == log_dir
      assert manifest["artifacts"]["codex_session"]["status"] == "not_applicable"

      categories =
        session_dir
        |> Path.join("events.jsonl")
        |> read_jsonl!()
        |> Enum.map(& &1["category"])

      assert "workspace_cleanup_preflight" in categories
      assert "workspace_cleanup_completed" in categories
    after
      File.rm_rf(test_root)
    end
  end

  test "cleanup preflight falls back to newest nested prloop state when logs lack statePath" do
    test_root = tmp_dir("evidence-cleanup-prloop-nested")
    logs_root = Path.join(test_root, "logs")
    workspace = Path.join(test_root, "workspace")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      create_git_workspace!(workspace)

      prloop_root = Path.join([workspace, ".git", "cloud-review-loop"])
      state_path = Path.join([prloop_root, "state", "run-456", "state.json"])
      File.mkdir_p!(Path.dirname(state_path))
      File.mkdir_p!(Path.join(prloop_root, "tmux"))
      File.write!(state_path, ~s({"state":"waiting","runId":"run-456"}))
      File.write!(Path.join([prloop_root, "tmux", "prloop.log"]), "review loop log without state path\n")

      context = %{
        issue_identifier: "DOC-54",
        run_id: "cleanup-nested-run",
        workspace_path: workspace
      }

      assert {:ok, _evidence_context} = Evidence.capture_workspace_cleanup_preflight(context, workspace)

      session_dir = Path.join([logs_root, "evidence", "sessions", "DOC-54", "cleanup-nested-run"])
      assert File.read!(Path.join([session_dir, "prloop", "state.json"])) =~ "waiting"

      manifest = read_json!(Path.join(session_dir, "manifest.json"))
      assert manifest["artifact_paths"]["prloop_state"] == "prloop/state.json"
      assert manifest["artifacts"]["prloop_state"]["source_path"] == state_path
      assert manifest["artifacts"]["prloop_state"]["discovery"] == "nested_state_search"
    after
      File.rm_rf(test_root)
    end
  end

  test "cleanup preflight ignores prloop logDir outside prloop root" do
    test_root = tmp_dir("evidence-cleanup-prloop-logdir")
    logs_root = Path.join(test_root, "logs")
    workspace = Path.join(test_root, "workspace")
    outside_log_dir = Path.join(test_root, "outside-logs")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      create_git_workspace!(workspace)

      prloop_root = Path.join([workspace, ".git", "cloud-review-loop"])
      state_path = Path.join([prloop_root, "state", "run-789", "state.json"])
      log_dir = Path.join(prloop_root, "tmux")
      File.mkdir_p!(Path.dirname(state_path))
      File.mkdir_p!(log_dir)
      File.mkdir_p!(outside_log_dir)
      File.write!(state_path, ~s({"state":"succeeded","runId":"run-789"}))

      File.write!(
        Path.join(log_dir, "prloop.log"),
        Jason.encode!(%{"statePath" => state_path, "logDir" => outside_log_dir}) <> "\n"
      )

      context = %{
        issue_identifier: "DOC-54",
        run_id: "cleanup-logdir-run",
        workspace_path: workspace
      }

      assert {:ok, _evidence_context} = Evidence.capture_workspace_cleanup_preflight(context, workspace)

      session_dir = Path.join([logs_root, "evidence", "sessions", "DOC-54", "cleanup-logdir-run"])
      manifest = read_json!(Path.join(session_dir, "manifest.json"))

      assert manifest["artifact_paths"]["prloop_log_dir"] == "prloop/logs"
      assert manifest["artifacts"]["prloop_log_dir"]["source_path"] == log_dir
      refute manifest["artifacts"]["prloop_log_dir"]["source_path"] == outside_log_dir
    after
      File.rm_rf(test_root)
    end
  end

  defp create_git_workspace!(workspace) do
    File.mkdir_p!(workspace)
    run!("git", ["-C", workspace, "init", "-b", "main"])
    run!("git", ["-C", workspace, "config", "user.name", "Test User"])
    run!("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "README.md"), "hello\n")
    run!("git", ["-C", workspace, "add", "README.md"])
    run!("git", ["-C", workspace, "commit", "-m", "initial"])
  end

  defp run!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("#{command} #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp tmp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
