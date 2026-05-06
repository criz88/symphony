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
      assert manifest["artifact_paths"]["events"] == "events.jsonl"
      assert manifest["artifact_paths"]["validation"] == "validation.jsonl"
      assert manifest["artifact_paths"]["git"] == "git.json"

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

  test "cleanup preflight writes git summary and preserves local prloop artifacts" do
    test_root = tmp_dir("evidence-cleanup-preflight")
    logs_root = Path.join(test_root, "logs")
    workspace = Path.join(test_root, "workspace")
    Application.put_env(:symphony_elixir, :logs_root, logs_root)

    try do
      create_git_workspace!(workspace)
      File.write!(Path.join(workspace, "uncommitted.txt"), "local work\n")

      prloop_root = Path.join([workspace, ".git", "cloud-review-loop"])
      File.mkdir_p!(Path.join(prloop_root, "tmux"))
      File.write!(Path.join(prloop_root, "state.json"), ~s({"state":"succeeded"}))
      File.write!(Path.join([prloop_root, "tmux", "prloop.log"]), "review loop log\n")

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
      assert File.read!(Path.join([session_dir, "prloop", "logs", "prloop.log"])) =~ "review loop log"

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
