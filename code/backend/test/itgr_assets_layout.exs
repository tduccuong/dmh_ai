# Tests for the session asset layout: Constants helpers, Util.Path resolver,
# Police path-safety check, and Jobs.pipeline + Jobs.origin persistence.

defmodule Itgr.AssetsLayout do
  use ExUnit.Case, async: true

  alias Dmhai.Constants
  alias Dmhai.Util.Path, as: SafePath
  alias Dmhai.Agent.{Jobs, Police}

  defp uid, do: T.uid()

  # ─── Constants helpers ──────────────────────────────────────────────────

  describe "Constants layout helpers" do
    test "session_root" do
      assert Constants.session_root("u@x.com", "S1") ==
               "/data/user_assets/u@x.com/S1"
    end

    test "session_data_dir" do
      assert Constants.session_data_dir("u@x.com", "S1") ==
               "/data/user_assets/u@x.com/S1/data"
    end

    test "session_origin_root for assistant / confidant only" do
      assert Constants.session_origin_root("u@x.com", "S", "assistant") ==
               "/data/user_assets/u@x.com/S/assistant/jobs"
      assert Constants.session_origin_root("u@x.com", "S", "confidant") ==
               "/data/user_assets/u@x.com/S/confidant/jobs"
    end

    test "job_workspace_dir" do
      assert Constants.job_workspace_dir("u@x.com", "S", "assistant", "J1") ==
               "/data/user_assets/u@x.com/S/assistant/jobs/J1"
    end

    test "session_origin_root rejects unknown origin" do
      assert_raise FunctionClauseError, fn ->
        Constants.session_origin_root("u@x.com", "S", "worker")
      end
    end

    test "sanitize replaces special chars with underscore" do
      assert Constants.sanitize("foo/bar baz") == "foo_bar_baz"
      assert Constants.sanitize("ok-file_name") == "ok-file_name"
    end
  end

  # ─── Util.Path resolver ─────────────────────────────────────────────────

  describe "SafePath.resolve" do
    defp ctx(root, ws, data) do
      %{session_root: root, workspace_dir: ws, data_dir: data}
    end

    test "relative path defaults to workspace" do
      ctx = ctx("/sr", "/sr/assistant/jobs/J1", "/sr/data")
      assert {:ok, "/sr/assistant/jobs/J1/foo.txt"} = SafePath.resolve("foo.txt", ctx)
    end

    test "'data/...' prefix resolves under data_dir" do
      ctx = ctx("/sr", "/sr/assistant/jobs/J1", "/sr/data")
      assert {:ok, "/sr/data/photo.jpg"} = SafePath.resolve("data/photo.jpg", ctx)
    end

    test "'workspace/...' prefix resolves under workspace_dir" do
      ctx = ctx("/sr", "/sr/assistant/jobs/J1", "/sr/data")
      assert {:ok, "/sr/assistant/jobs/J1/out.csv"} =
               SafePath.resolve("workspace/out.csv", ctx)
    end

    test "absolute path inside session_root is accepted" do
      ctx = ctx("/sr", "/sr/ws", "/sr/data")
      assert {:ok, "/sr/data/x"} = SafePath.resolve("/sr/data/x", ctx)
    end

    test "absolute path outside session_root is rejected" do
      ctx = ctx("/sr", "/sr/ws", "/sr/data")
      assert {:error, reason} = SafePath.resolve("/etc/passwd", ctx)
      assert String.contains?(reason, "escapes")
    end

    test "relative path with ../ that escapes root is rejected" do
      ctx = ctx("/sr", "/sr/assistant/jobs/J1", "/sr/data")
      # ../../../ jumps above /sr
      assert {:error, reason} = SafePath.resolve("../../../../etc/passwd", ctx)
      assert String.contains?(reason, "escapes")
    end

    test "within?/2 correctly distinguishes subpaths" do
      assert SafePath.within?("/sr/data/x", "/sr")
      assert SafePath.within?("/sr", "/sr")
      refute SafePath.within?("/sr2/data", "/sr")
      refute SafePath.within?("/sr-poison", "/sr")
    end
  end

  # ─── Jobs pipeline + origin columns ─────────────────────────────────────

  describe "Jobs.insert / Jobs.get with pipeline + origin" do
    test "persists pipeline='assistant' origin='assistant' by default" do
      jid = Jobs.insert(user_id: uid(), session_id: uid(),
                        job_title: "t", job_spec: "s")
      j = Jobs.get(jid)
      assert j.pipeline == "assistant"
      assert j.origin   == "assistant"
    end

    test "round-trips pipeline='confidant' + origin='confidant'" do
      jid = Jobs.insert(user_id: uid(), session_id: uid(),
                        job_title: "t", job_spec: "s",
                        pipeline: "confidant", origin: "confidant")
      j = Jobs.get(jid)
      assert j.pipeline == "confidant"
      assert j.origin   == "confidant"
    end

    test "round-trips mixed pipeline/origin (assistant-origin running confidant pipeline)" do
      jid = Jobs.insert(user_id: uid(), session_id: uid(),
                        job_title: "t", job_spec: "s",
                        pipeline: "confidant", origin: "assistant")
      j = Jobs.get(jid)
      assert j.pipeline == "confidant"
      assert j.origin   == "assistant"
    end
  end

  # ─── Police path-safety check ───────────────────────────────────────────

  describe "Police.check_tool_calls path safety" do
    defp path_ctx do
      %{
        session_root:  "/data/user_assets/u/S",
        workspace_dir: "/data/user_assets/u/S/assistant/jobs/J1",
        data_dir:      "/data/user_assets/u/S/data"
      }
    end

    test "accepts read_file inside session root" do
      call = T.tool_call("read_file", %{"path" => "report.txt"})
      assert :ok = Police.check_tool_calls([call], [], path_ctx())
    end

    test "accepts read_file on data/ prefix" do
      call = T.tool_call("read_file", %{"path" => "data/photo.jpg"})
      assert :ok = Police.check_tool_calls([call], [], path_ctx())
    end

    test "rejects read_file with absolute path outside session root" do
      call = T.tool_call("read_file", %{"path" => "/etc/passwd"})
      assert {:rejected, reason} = Police.check_tool_calls([call], [], path_ctx())
      assert String.contains?(reason, "path_violation")
    end

    test "rejects write_file that escapes with ../" do
      call = T.tool_call("write_file", %{"path" => "../../../../etc/hack", "content" => "x"})
      assert {:rejected, reason} = Police.check_tool_calls([call], [], path_ctx())
      assert String.contains?(reason, "path_violation")
    end

    test "accepts bash rm inside the workspace" do
      call = T.tool_call("bash", %{"command" => "rm -rf tmp/cache"})
      assert :ok = Police.check_tool_calls([call], [], path_ctx())
    end

    test "rejects bash rm on an absolute path outside the workspace" do
      call = T.tool_call("bash", %{"command" => "rm -rf /data/user_assets/u/S/data/photo.jpg"})
      assert {:rejected, reason} = Police.check_tool_calls([call], [], path_ctx())
      assert String.contains?(reason, "path_violation")
      assert String.contains?(reason, "outside the job workspace")
    end

    test "rejects spawn_task rm outside workspace" do
      call = T.tool_call("spawn_task", %{"command" => "rmdir /data/user_assets/u/S/data"})
      assert {:rejected, _reason} = Police.check_tool_calls([call], [], path_ctx())
    end

    test "no path checks when ctx has no session_root (legacy callers)" do
      call = T.tool_call("read_file", %{"path" => "/etc/passwd"})
      assert :ok = Police.check_tool_calls([call], [], %{})
    end
  end
end
