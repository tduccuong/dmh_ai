# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R13.
#
# `RunScript.harden/1` prepends `set -o pipefail` to every shell-shebang
# script before sending it to the sandbox. Without this, a failing
# `curl … | jq …` swallows curl's non-zero exit because jq returns 0,
# and the model misreads "no data" as "the API returned empty" instead
# of "the upstream errored". The whole HTTP-visibility guarantee in
# `<reading_tool_results>` of the system prompt depends on this.
#
# The harden function itself has unit-level coverage. R13 pins the
# end-to-end contract at the sandbox-runtime layer: a `false | true`
# pipeline run through `RunScript.execute/2` must report the LEFTMOST
# non-zero exit, proving pipefail reached the sandbox shell.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R13PipefailPreludeInjection do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.RunScript

  test "pipefail is active: `false | true; echo $?` prints 1, not 0" do
    ctx = SandboxCase.fresh_admin_ctx()
    File.mkdir_p!(Constants.session_workspace_dir(ctx.user_email, ctx.session_id))

    # No shebang on purpose — harden/1 prepends `#!/bin/bash\n` +
    # the safety prelude (including `set -o pipefail`).
    script = "false | true\necho EXIT=$?"

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    out = to_string(output)

    assert String.contains?(out, "EXIT=1"),
           """
           pipefail prelude did NOT inject. Pipeline `false | true` returned
           the rightmost exit (true=0) instead of the leftmost non-zero
           (false=1). This breaks every shell pipeline that pipes a
           potentially-failing command into a parser — the model sees a
           clean exit and reports "empty result" instead of "upstream
           error". Output was: #{inspect(out)}
           """

    refute String.contains?(out, "EXIT=0"),
           "expected EXIT=1 (leftmost non-zero); EXIT=0 means pipefail is missing"
  end

  test "explicit opt-out: `set +o pipefail` restores default pipeline semantics" do
    ctx = SandboxCase.fresh_admin_ctx()
    File.mkdir_p!(Constants.session_workspace_dir(ctx.user_email, ctx.session_id))

    # Documented escape hatch (run_script tool description) for the
    # rare `cmd | head -N` early-close pattern. Verify it actually
    # works — without the opt-out the script would print EXIT=1.
    script = """
    set +o pipefail
    false | true
    echo EXIT=$?
    """

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    out = to_string(output)

    assert String.contains?(out, "EXIT=0"),
           """
           `set +o pipefail` opt-out did not take effect — pipeline still
           reports leftmost non-zero. The escape hatch documented in the
           tool description doesn't work. Output: #{inspect(out)}
           """
  end
end
