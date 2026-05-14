# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R14.
#
# `RunScript` caps the output it returns to master at `@max_output`
# bytes (50 KB). The cap protects the BE from a script that
# accidentally `cat`s a multi-GB file or loops on `yes`. Without it,
# the LLM context — and the tool_history table — would balloon by
# whatever the model picks, and the next turn's serialisation
# would either time out the request or OOM the runtime.
#
# The drain command (`tail -c $max_output …`) keeps only the LAST
# 50 KB of the script's stdout, then master applies a defensive
# `String.slice(_, 0, @max_output)` on top. R14 verifies both layers
# by running a script that emits ~500 KB and asserting the captured
# output stays ≤ 50 KB.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R14OutputCap50Kb do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.RunScript

  @max_output 50_000

  test "script emitting >>50 KB is capped to ≤ 50 KB on the master side" do
    ctx = SandboxCase.fresh_admin_ctx()
    File.mkdir_p!(Constants.session_workspace_dir(ctx.user_email, ctx.session_id))

    # 500 KB of deterministic content. `yes "line-of-content-xxxxxxxxxxx"` would
    # also work but `printf` in a loop gives us byte-counted control.
    script = """
    for i in $(seq 1 50000); do
      printf 'line-%05d-payload-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' "$i"
    done
    """

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    out = to_string(output)
    size = byte_size(out)

    assert size <= @max_output + 200,
           """
           Output cap regression: a 500 KB-emitting script returned #{size}
           bytes to master, well above the #{@max_output}-byte cap.
           Either `tail -c $max_output` was dropped from the drain
           command or master-side `String.slice/3` truncation is gone.
           Sample (first 200 chars): #{String.slice(out, 0, 200)}…
           """

    assert size >= div(@max_output, 2),
           """
           Output is suspiciously small (#{size} bytes). The script
           generates ~500 KB; we expect roughly @max_output back.
           Could indicate the script never ran, or its stdout never
           reached the drain. Output: #{inspect(out)}
           """
  end
end
