# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R07.
#
# `mk_download_link` is the master-mediated bridge that surfaces a
# workspace file as a downloadable URL. R07 pins the contract:
#
#   1. Happy path: a file the model wrote into its workspace via
#      run_script ends up at <assets>/<email>/<session>/data/published/
#      under a collision-resistant `<rand>_<basename>` name.
#   2. Path-traversal guard: a `../../etc/passwd` attempt is rejected
#      cleanly — the security boundary that keeps published/ from
#      becoming an arbitrary filesystem reader.
#   3. Returned URL points at where /assets/<session>/published/<file>
#      will resolve.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R07MkDownloadLink do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.MkDownloadLink

  test "publishes a workspace file under data/published/<rand>_<basename> and returns a URL" do
    ctx = SandboxCase.fresh_admin_ctx()

    # Stage: master pre-creates the workspace + a file the model
    # would have written via run_script.
    workspace = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "solution.pdf"), "FAKE-PDF-CONTENT")

    assert {:ok, %{url: url, name: name, link: link, size: size}} =
             MkDownloadLink.execute(%{"file" => "solution.pdf"}, ctx)

    assert size == byte_size("FAKE-PDF-CONTENT")
    assert String.ends_with?(name, "_solution.pdf")
    assert String.starts_with?(url, "/assets/#{ctx.session_id}/published/")

    # The URL is signed: query string carries `expires` + `sig`. Both
    # must be present and the path before `?` must end with the
    # generated basename.
    assert [path_part, qs] = String.split(url, "?", parts: 2)
    assert String.ends_with?(path_part, name)
    assert qs =~ ~r/\bexpires=\d+/
    assert qs =~ ~r/\bsig=[a-f0-9]{64}/

    # Markdown link: `[<display>](<url>)` with the publish prefix
    # stripped from the link text so users see the original name.
    assert link == "[solution.pdf](#{url})"

    # Round-trip verify: the same params we built must validate.
    [_, query] = String.split(url, "?", parts: 2)
    params = URI.decode_query(query)
    rel = "published/#{name}"
    assert :ok = DmhAi.Auth.SignedUrl.verify(params, ctx.session_id, rel)

    # Tamper with the sig → invalid. Replace with all-zeros (1 in 2^256
    # chance of collision with the real sig — effectively never).
    tampered = Map.put(params, "sig", String.duplicate("0", 64))
    assert {:error, :invalid} = DmhAi.Auth.SignedUrl.verify(tampered, ctx.session_id, rel)

    # Tamper with the path → invalid (sig was for `published/<name>`,
    # not `published/other.pdf`).
    assert {:error, :invalid} =
             DmhAi.Auth.SignedUrl.verify(params, ctx.session_id, "published/other.pdf")

    # File landed where /assets handler will look for it.
    published = Constants.session_published_dir(ctx.user_email, ctx.session_id)
    host_file = Path.join(published, name)
    assert File.exists?(host_file)
    assert File.read!(host_file) == "FAKE-PDF-CONTENT"
  end

  test "rejects path-traversal attempts" do
    ctx = SandboxCase.fresh_admin_ctx()
    workspace = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace)

    # `../../etc/passwd` from inside workspace must NOT escape.
    assert {:error, msg} = MkDownloadLink.execute(%{"file" => "../../../etc/passwd"}, ctx)
    assert msg =~ "escapes the session workspace"

    # Absolute path outside workspace must be rejected too.
    assert {:error, msg2} = MkDownloadLink.execute(%{"file" => "/etc/passwd"}, ctx)
    assert msg2 =~ "escapes the session workspace"
  end

  test "rejects missing files cleanly (not as a traversal error)" do
    ctx = SandboxCase.fresh_admin_ctx()
    workspace = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace)

    assert {:error, msg} = MkDownloadLink.execute(%{"file" => "nonexistent.pdf"}, ctx)
    assert msg =~ "does not exist"
  end
end
