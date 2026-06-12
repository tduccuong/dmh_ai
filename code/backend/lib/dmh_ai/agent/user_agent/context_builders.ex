# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.ContextBuilders do
  @moduledoc """
  Small read/query/format helpers the chain loop and the Confidant
  pipeline lean on:

  * User-row lookups: email / role
  * Image / video description loads for the session
  * Effective-images decision (skip already-described attachments)
  * Web-context formatting from the search engine's `%{snippets, pages}`
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ── web context ─────────────────────────────────────────────────────────

  @doc """
  Format the engine's `%{snippets, pages}` result into a single
  capped string suitable for inclusion in the Confidant prompt.
  Returns `nil` if the result is empty.
  """
  def build_web_context(_content, %{snippets: [], pages: []}, _reply_pid), do: nil

  def build_web_context(_content, result_map, _reply_pid) do
    raw = format_raw_results(result_map)

    if raw == "" do
      nil
    else
      String.slice(raw, 0, AgentSettings.web_results_max_chars())
    end
  end

  @doc "Splice page content (or fall back to snippet) into a numbered list."
  def format_raw_results(%{snippets: snippets, pages: pages}) do
    pages_by_url = Map.new(pages, fn p -> {p.url, p.content} end)

    snippets
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {s, i} ->
      content = Map.get(pages_by_url, s.url) || s.snippet

      if content != "" do
        ["#{i}. #{s.title}\n#{content}"]
      else
        []
      end
    end)
    |> Enum.join("\n\n")
  end

  # ── image / video / attachment ──────────────────────────────────────────

  @doc "Load all `image_descriptions` rows for the session."
  def load_image_descriptions(session_id) do
    try do
      result = query!(Repo, "SELECT name, description FROM image_descriptions WHERE session_id=?",
                      [session_id])
      Enum.map(result.rows, fn [name, desc] -> %{name: name, description: desc} end)
    rescue
      _ -> []
    end
  end

  @doc "Load all `video_descriptions` rows for the session."
  def load_video_descriptions(session_id) do
    try do
      result = query!(Repo, "SELECT name, description FROM video_descriptions WHERE session_id=?",
                      [session_id])
      Enum.map(result.rows, fn [name, desc] -> %{name: name, description: desc} end)
    rescue
      _ -> []
    end
  end

  @doc """
  Drop attachments that already have a stored description (image or
  video) so the model isn't re-shown what it already remembers.
  """
  def effective_images(command, image_descriptions, video_descriptions) do
    cond do
      command.images == [] ->
        []

      command.has_video ->
        video_name = List.first(command.image_names) || "video"
        if Enum.any?(video_descriptions, &(&1.name == video_name)), do: [], else: command.images

      true ->
        all_described? = Enum.all?(command.image_names, fn name ->
          Enum.any?(image_descriptions, &(&1.name == name))
        end)
        if all_described?, do: [], else: command.images
    end
  end

  # ── user-row lookups ────────────────────────────────────────────────────

  @doc "Read `users.email` (empty string on miss)."
  def lookup_user_email(user_id) do
    try do
      case query!(Repo, "SELECT email FROM users WHERE id=?", [user_id]) do
        %{rows: [[email]]} when is_binary(email) -> email
        _ -> ""
      end
    rescue
      _ -> ""
    end
  end

  @doc "Read `users.role` (defaults to `\"user\"` on miss)."
  def lookup_user_role(user_id) do
    try do
      case query!(Repo, "SELECT role FROM users WHERE id=?", [user_id]) do
        %{rows: [[role]]} when is_binary(role) -> role
        _ -> "user"
      end
    rescue
      _ -> "user"
    end
  end

  # ── form extraction + chain-end + cancel ────────────────────────────────

  @doc """
  When the model called a tool that may emit a form (request_input /
  connect_mcp), pull the first `%{form: form}` envelope out of the
  exec results so the chain can persist it on the assistant message.
  """
  def extract_form_from_results(exec_results) do
    Enum.find_value(exec_results, fn
      {:ok, %{form: form}} when is_map(form) -> form
      _                                       -> nil
    end)
  end

  @doc "Narration to put on the assistant message when a form is emitted but the model didn't write one."
  def fallback_content_for_form(form) when is_map(form) do
    case form["kind"] || form[:kind] do
      "connect_mcp_setup" -> "Setting up the connection — please fill in the form below."
      _                   -> "Please fill in the form below."
    end
  end
  def fallback_content_for_form(_), do: "Please fill in the form below."

  @doc """
  Pull the `signal_blocker` blocker envelope out of a turn's tool
  results. Returns nil when none of the calls signalled a blocker.
  Mirrors `extract_form_from_results/1`.
  """
  def extract_blocker_from_results(exec_results) do
    Enum.find_value(exec_results, fn
      {:ok, %{blocker: %{} = blocker}} -> blocker
      _                                 -> nil
    end)
  end

  @doc """
  Compose the user-visible message for a blocker-terminated chain.
  Model narration (if any) goes first; the blocker reason is the
  closing sentence so the user sees the explicit gap statement last.
  When the model wrote no narration, the reason stands alone.
  """
  def compose_blocker_message(narration, blocker) when is_binary(narration) and is_map(blocker) do
    reason = blocker[:reason] || blocker["reason"] || ""

    case String.trim(narration) do
      "" -> reason
      n  -> n <> "\n\n" <> reason
    end
  end

  def compose_blocker_message(_, blocker) when is_map(blocker),
    do: blocker[:reason] || blocker["reason"] || ""
end
