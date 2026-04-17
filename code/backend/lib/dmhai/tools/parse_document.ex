# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ParseDocument do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Util.Path, as: SafePath
  require Logger

  @max_chars    200_000

  # Extensions handled by pandoc (docx, odt, pptx, etc.)
  @pandoc_exts MapSet.new([".docx", ".odt", ".odp", ".pptx", ".rtf", ".epub", ".html", ".htm", ".rst"])

  # Extensions that are already plain text — read directly.
  @text_exts MapSet.new([".txt", ".md", ".csv", ".tsv", ".log", ".json", ".xml",
                         ".yaml", ".yml", ".toml", ".ini", ".cfg"])

  @impl true
  def name, do: "parse_document"

  @impl true
  def description,
    do: "Parse a document file and return its content as plain text or Markdown. " <>
        "Supports PDF (requires pdftotext), DOCX/ODT/PPTX/EPUB/HTML/RTF (requires pandoc), " <>
        "and plain-text formats."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Path to the document file (.pdf, .docx, .odt, .pptx, .epub, .html, .txt, etc.). " <>
                         "Resolved within your sandbox or uploaded assets."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path}, ctx) when is_binary(path) do
    with {:ok, abs}  <- SafePath.resolve(path, ctx),
         :ok         <- exists_check(abs),
         {:ok, text} <- do_parse(abs) do
      truncated = String.length(text) > @max_chars
      result    = String.slice(text, 0, @max_chars)
      result    = if truncated, do: result <> "\n\n[truncated: document exceeds #{@max_chars} characters]", else: result
      {:ok, result}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: path"}

  # ── private ────────────────────────────────────────────────────────────────

  defp exists_check(abs) do
    if File.exists?(abs), do: :ok, else: {:error, "File not found: #{abs}"}
  end

  defp do_parse(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext == ".pdf"                        -> parse_pdf(path)
      MapSet.member?(@pandoc_exts, ext)    -> run_pandoc(path)
      MapSet.member?(@text_exts, ext)      -> File.read(path)
      true                                 -> try_pandoc_then_read(path)
    end
  end

  # Try pdftotext (poppler-utils) first — preserves layout better.
  # Falls back to pandoc if pdftotext is unavailable or returns empty output.
  defp parse_pdf(path) do
    try do
      case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
        {output, 0} when output != "" -> {:ok, output}
        _                             -> run_pandoc(path)
      end
    rescue
      _ -> run_pandoc(path)
    end
  end

  defp run_pandoc(path) do
    try do
      case System.cmd("pandoc", ["--to=markdown", "--wrap=none", path],
                      stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {err, code} ->
          Logger.warning("[ParseDocument] pandoc exited #{code}: #{String.slice(err, 0, 200)}")
          {:error, "pandoc failed (exit #{code}): #{String.slice(err, 0, 200)}"}
      end
    rescue
      _ -> {:error, "pandoc is not installed — cannot parse this document format"}
    end
  end

  defp try_pandoc_then_read(path) do
    case run_pandoc(path) do
      {:ok, _} = ok -> ok
      _             -> File.read(path)
    end
  end
end
