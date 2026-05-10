# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R08.
#
# The sandbox image preinstalls a deliverable lib set (fpdf2, openpyxl,
# python-docx, Pillow, matplotlib, markdown, pyyaml). Without these,
# the model thrashes through pip-install attempts that all hit the
# iptables LAN fence — see session 1778431857991's 5-script PDF
# nightmare for the failure mode this replaces.
#
# R08 boots the production-shape sandbox container (the one
# `scripts/test.sandbox.sh` started for the suite) and verifies:
#
#   1. `import fpdf` in a fresh `run_script` succeeds — first try, no
#      install needed. This is the load-bearing assertion.
#   2. The generated `.pdf` file is a real PDF (starts with the `%PDF-`
#      magic), not a hand-rolled "PDF-like structure" placeholder.
#   3. `mk_download_link` then surfaces it via a signed URL.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R08PreinstalledLibs do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.{RunScript, MkDownloadLink}

  test "fpdf2 is preinstalled — model can generate a real PDF without pip-install" do
    ctx = SandboxCase.fresh_admin_ctx()

    workspace = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace)

    script = """
    #!/usr/bin/env python3
    from fpdf import FPDF
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font('Helvetica', size=14)
    pdf.cell(0, 10, 'sandbox-runtime test')
    pdf.output('out.pdf')
    print('OK')
    """

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    assert String.contains?(to_string(output), "OK"),
           "fpdf2 import + render must succeed in the preinstalled sandbox; got: #{inspect(output)}"

    pdf_path = Path.join(workspace, "out.pdf")
    assert File.exists?(pdf_path)

    # Real PDFs start with `%PDF-`. A hand-rolled placeholder (the
    # failure mode we're guarding against) wouldn't.
    head = File.read!(pdf_path) |> binary_part(0, 5)
    assert head == "%PDF-", "expected real PDF magic; got #{inspect(head)}"

    assert {:ok, %{url: url, link: link}} =
             MkDownloadLink.execute(%{"file" => "out.pdf"}, ctx)

    assert String.starts_with?(url, "/assets/#{ctx.session_id}/published/")
    assert String.contains?(link, ".pdf")
  end

  test "openpyxl is preinstalled — Excel .xlsx generation works first try" do
    ctx = SandboxCase.fresh_admin_ctx()
    workspace = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace)

    script = """
    #!/usr/bin/env python3
    from openpyxl import Workbook
    wb = Workbook()
    wb.active['A1'] = 'sandbox runtime'
    wb.save('out.xlsx')
    print('OK')
    """

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    assert String.contains?(to_string(output), "OK")

    out = Path.join(workspace, "out.xlsx")
    assert File.exists?(out)

    # `.xlsx` is a ZIP container — magic bytes "PK\x03\x04".
    head = File.read!(out) |> binary_part(0, 4)
    assert head == <<0x50, 0x4B, 0x03, 0x04>>, "expected ZIP/xlsx magic; got #{inspect(head)}"
  end

  test "Pillow is preinstalled — image generation works first try" do
    ctx = SandboxCase.fresh_admin_ctx()
    workspace = Constants.session_workspace_dir(ctx.user_email, ctx.session_id)
    File.mkdir_p!(workspace)

    script = """
    #!/usr/bin/env python3
    from PIL import Image
    img = Image.new('RGB', (10, 10), 'red')
    img.save('out.png')
    print('OK')
    """

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    assert String.contains?(to_string(output), "OK")

    out = Path.join(workspace, "out.png")
    assert File.exists?(out)

    # PNG magic: 89 50 4E 47 0D 0A 1A 0A
    head = File.read!(out) |> binary_part(0, 8)
    assert head == <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  end
end
