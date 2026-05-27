# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.MkDownloadLink do
  @moduledoc """
  `mk_download_link({file: "<workspace-relative-path>"})` — surface a
  workspace file as a downloadable URL.

  Sandbox-side run_script writes land in
  `/data/user_workspaces/<email>/<session>/`. That tree is RW for the
  per-user sandbox process but NOT served by any HTTP endpoint. When
  the user has asked for a file artifact (PDF, CSV, archive, image,
  …), the model invokes this tool. The runtime is the master-mediated
  bridge: master copies the workspace file into
  `/data/user_assets/<email>/<session>/data/published/<rand>_<basename>`
  (the `user_assets` tree IS served by `GET /assets/<session>/<rest>`),
  and returns the URL. The model pastes the URL into its reply; the FE
  markdown renderer makes it clickable.

  See architecture.md §Execution tools → `mk_download_link`.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Constants
  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Auth.SignedUrl

  @impl true
  def name, do: "mk_download_link"

  @impl true
  def description do
    """
    Surface a workspace file as a downloadable link. Use when the user asked for an artifact (PDF, CSV, screenshot, archive, etc.). `file` is the path under your workspace. Returns the URL — paste it verbatim into your reply so the user can click to download.

    `mk_download_link(file)` — surface a workspace file as a downloadable URL.

    Files you produce in your workspace via `run_script` (PDFs, CSVs, archives, screenshots, anything generated) are sandbox scratch — the user can't reach them through any URL by default. Call `mk_download_link({file: "<workspace-relative-path>"})` to publish a single file; the runtime copies it into a served location and returns the URL.

    When to use: the user asked for a deliverable they should be able to download. Examples of the SHAPE — *"export this as PDF"*, *"give me a CSV of the results"*, *"can I have a screenshot of that"*, *"package this up as a zip"*.

    When NOT to use: intermediate files (drafts, temp output, debug dumps) the user didn't ask for. Don't publish your scratch — it clutters their session view.

    Returns `{url, name, link, size}`. Paste the `link` field verbatim into your reply — it's a markdown-formatted clickable link (`[<name>](<url>)`). Example reply: *"Here's your file: [solution.pdf](/assets/...)"*. Don't reformat — the markdown form is what makes the URL clickable in the chat.

    Limits: 50 MB per file (configurable). Files under your workspace only — absolute paths outside it are rejected.
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          file: %{
            type: "string",
            description:
              "Path to the file under your workspace. Relative paths are resolved against the " <>
                "session workspace root; absolute paths must already be inside it."
          }
        },
        required: ["file"]
      }
    }
  end

  @impl true
  def execute(%{"file" => raw_path}, ctx)
      when is_binary(raw_path) and raw_path != "" do
    email      = Map.get(ctx, :user_email) || ""
    session_id = Map.get(ctx, :session_id) || ""

    cond do
      email == "" or session_id == "" ->
        {:error, "missing session context (user_email or session_id empty)"}

      true ->
        workspace = Constants.session_workspace_dir(email, session_id)

        with {:ok, src}        <- resolve_inside_workspace(raw_path, workspace),
             {:ok, %{size: sz}} <- File.stat(src),
             :ok                <- check_size(sz),
             {:ok, dest_path}   <- copy_to_published(src, email, session_id) do
          url      = url_for(session_id, dest_path)
          basename = Path.basename(dest_path)
          # `link` is the markdown-formatted form. The model pastes it
          # verbatim into its reply and the FE markdown renderer turns
          # it into a clickable link. Bare relative URLs (`/assets/...`)
          # are NOT autolinked by GFM, so handing the model a
          # ready-to-paste link string keeps the contract idiot-proof.
          # `display_name` strips the random publish prefix so the
          # link text reads as the original filename.
          display_name = strip_publish_prefix(basename)
          link = "[#{display_name}](#{url})"

          {:ok, %{url: url, name: basename, link: link, size: sz}}
        end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: file"}

  # ─── private ──────────────────────────────────────────────────────────────

  # Resolve `raw_path` (relative or absolute) under `workspace`.
  # Reject any path that escapes the workspace tree after expansion —
  # this is the path-traversal guard.
  defp resolve_inside_workspace(raw_path, workspace) do
    candidate =
      if Path.type(raw_path) == :absolute do
        raw_path
      else
        Path.join(workspace, raw_path)
      end

    expanded = Path.expand(candidate)
    workspace_real = Path.expand(workspace)

    cond do
      not String.starts_with?(expanded, workspace_real <> "/") and expanded != workspace_real ->
        {:error, "file path escapes the session workspace"}

      not File.regular?(expanded) ->
        {:error, "file does not exist or is not a regular file: #{Path.relative_to(expanded, workspace_real)}"}

      true ->
        {:ok, expanded}
    end
  end

  defp check_size(size) do
    cap = AgentSettings.publish_max_bytes()

    if size > cap do
      {:error,
       "file is too large to publish: #{size} bytes > limit #{cap} bytes (publishMaxBytes setting)"}
    else
      :ok
    end
  end

  # Copy the workspace file into `<assets>/<email>/<session>/data/published/`
  # under a collision-resistant `<rand>_<basename>` name. Master runs as
  # root, so the copy + permissions both succeed unconditionally.
  defp copy_to_published(src, email, session_id) do
    published = Constants.session_published_dir(email, session_id)
    File.mkdir_p!(published)

    base = src |> Path.basename() |> sanitize_basename()
    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    dest = Path.join(published, "#{rand}_#{base}")

    case File.cp(src, dest) do
      :ok ->
        File.chmod!(dest, 0o644)
        {:ok, dest}

      {:error, reason} ->
        {:error, "failed to copy file into published/: #{inspect(reason)}"}
    end
  end

  # Strip everything but alphanumerics, dash, underscore, dot.
  # Empty result falls back to `unnamed`.
  defp sanitize_basename(name) do
    cleaned = Regex.replace(~r/[^\w\-\.]/, name, "_")
    if cleaned == "", do: "unnamed", else: cleaned
  end

  # `/assets/<session_id>/published/<rand>_<basename>?expires=…&sig=…` —
  # the signed URL form. Anyone holding the URL can download until
  # expiry without a bearer token, so the link is shareable. See
  # architecture.md §Execution tools → mk_download_link → Signed URLs.
  defp url_for(session_id, dest_path) do
    rel_path = "published/#{Path.basename(dest_path)}"
    qs = SignedUrl.query(session_id, rel_path, AgentSettings.publish_link_ttl_secs())
    "/assets/#{session_id}/#{rel_path}#{qs}"
  end

  # Strip the leading 8-hex random prefix (e.g. `abc12345_solution.pdf`
  # → `solution.pdf`) so the user-visible link text is the original
  # filename. `/assets` handler does the same strip on the
  # `Content-Disposition: attachment; filename=` header.
  defp strip_publish_prefix(basename),
    do: Regex.replace(~r/^[a-f0-9]{8,}_/, basename, "")
end
