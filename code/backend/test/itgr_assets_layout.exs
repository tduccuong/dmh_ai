# Tests for the session asset layout: Constants helpers, Util.Path resolver,
# Police path-safety check, and Tasks.pipeline + Tasks.origin persistence.

defmodule Itgr.AssetsLayout do
  use ExUnit.Case, async: true

  alias Dmhai.Constants
  alias Dmhai.Util.Path, as: SafePath
  alias Dmhai.Agent.{Tasks, Police}

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

    test "session_workspace_dir" do
      assert Constants.session_workspace_dir("u@x.com", "S") ==
               "/data/user_assets/u@x.com/S/workspace"
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
      ctx = ctx("/sr", "/sr/workspace", "/sr/data")
      assert {:ok, "/sr/workspace/foo.txt"} = SafePath.resolve("foo.txt", ctx)
    end

    test "'data/...' prefix resolves under data_dir" do
      ctx = ctx("/sr", "/sr/workspace", "/sr/data")
      assert {:ok, "/sr/data/photo.jpg"} = SafePath.resolve("data/photo.jpg", ctx)
    end

    test "'workspace/...' prefix resolves under workspace_dir" do
      ctx = ctx("/sr", "/sr/workspace", "/sr/data")
      assert {:ok, "/sr/workspace/out.csv"} =
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
      ctx = ctx("/sr", "/sr/workspace", "/sr/data")
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

  # ─── Police path-safety check ───────────────────────────────────────────

  describe "Police.check_tool_calls path safety" do
    defp path_ctx do
      %{
        session_root:  "/data/user_assets/u/S",
        workspace_dir: "/data/user_assets/u/S/assistant/tasks/J1",
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
      call = T.tool_call("run_script", %{"script" => "rm -rf tmp/cache"})
      assert :ok = Police.check_tool_calls([call], [], path_ctx())
    end

    test "rejects bash rm on an absolute path outside the workspace" do
      call = T.tool_call("run_script", %{"script" => "rm -rf /data/user_assets/u/S/data/photo.jpg"})
      assert {:rejected, reason} = Police.check_tool_calls([call], [], path_ctx())
      assert String.contains?(reason, "path_violation")
      assert String.contains?(reason, "outside the session workspace")
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
