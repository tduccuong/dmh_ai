# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.Gettext do
  @moduledoc """
  `/gettext` runtime: vision-model OCR + sentence segmentation for each
  image attached to the current Confidant message. Persists an assistant
  message whose `gettext.sentences` field is the rendered Read-out-loud
  payload (FE renders each sentence on its own line with a speaker icon
  beside it).

  Confidant-mode only — Assistant mode is intercepted upstream with a
  short hint redirecting the user to switch modes.

  No LLM round-trip on the assistant model; one vision call per image
  attachment in the user's message.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM, UserAgentMessages}
  alias DmhAi.Constants

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)

  # Magick resize ceiling — same value ExtractContent uses for its
  # image-describer path. Vision tokens are dominated by pixel count;
  # 1568 px is the published Anthropic guidance for Claude vision and
  # works fine across the gemma / Llava family too.
  @resize_max_dim 1568

  @vision_prompt """
  Extract every readable piece of human text from the image, in reading
  order. Output STRICT JSON with one key:

    {"sentences": ["First sentence.", "Second sentence."]}

  Rules:
    - One sentence per array element. Split on terminal punctuation
      (. ! ?), line breaks that clearly end a thought, and paragraph
      boundaries. Don't split on commas, semicolons, or mid-sentence
      colons.
    - Preserve the original language exactly — do NOT translate.
    - If the image has bullet points or list items, each item is its
      own sentence.
    - If the image has no readable text, return {"sentences": []}.
    - Do NOT add commentary, explanation, or markdown fences around
      the JSON. The first character must be `{`.
  """

  @doc """
  Public entry. Returns `{:ok, payload}` for the command finalizer, where
  `payload` is the structured assistant-message attachment (the FE
  receives it on `messages[-1].gettext`).

  `attachment_names` is the list of files the FE uploaded to the
  session workspace via `/upload-session-attachment` — passed in
  directly so the command pipeline doesn't depend on the BE having
  inlined `📎 workspace/<name>` markers into the stored content.
  Confidant-mode messages keep their clean text; the marker pipeline
  is assistant-mode-only.
  """
  @spec run(String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:handled, non_neg_integer()}
  def run(original_content, session_id, user_id, _lang, attachment_names \\ []) do
    image_names = Enum.filter(attachment_names || [], &image_name?/1)

    cond do
      image_names == [] ->
        finalize_with_payload(session_id, user_id, original_content,
          %{sentences: [], images: [], error: "no_image_attached"},
          "Attach an image, then `/gettext` will extract its text and offer Read-out-loud playback.")

      true ->
        user_email = lookup_user_email(user_id)
        workspace = Constants.session_workspace_dir(user_email, session_id)
        {per_image, all_sentences} = extract_per_image(image_names, workspace)
        gettext_payload = %{sentences: all_sentences, images: per_image}
        fallback = compose_fallback_text(per_image, all_sentences)
        finalize_with_payload(session_id, user_id, original_content, gettext_payload, fallback)
    end
  end

  # ── attachment helpers ─────────────────────────────────────────────────

  defp image_name?(name) when is_binary(name) do
    ext = name |> Path.extname() |> String.downcase()
    ext in @image_exts
  end

  defp image_name?(_), do: false

  # ── per-image extraction ───────────────────────────────────────────────

  defp extract_per_image(image_names, workspace) do
    {per_image_rev, all_rev} =
      Enum.reduce(image_names, {[], []}, fn name, {imgs, acc} ->
        path = Path.join(workspace, name)
        case extract_one(path) do
          {:ok, sentences} ->
            entry = %{name: name, status: "ok", count: length(sentences)}
            {[entry | imgs], Enum.reverse(sentences) ++ acc}

          {:empty, _} ->
            {[%{name: name, status: "empty", count: 0} | imgs], acc}

          {:error, reason} ->
            Logger.warning("[Gettext] image=#{name} err=#{inspect(reason)}")
            {[%{name: name, status: "error", error: to_string(reason), count: 0} | imgs], acc}
        end
      end)

    {Enum.reverse(per_image_rev), Enum.reverse(all_rev)}
  end

  defp extract_one(path) do
    case scale_and_encode(path) do
      {:ok, b64} ->
        messages = [%{role: "user", content: @vision_prompt, images: [b64]}]
        case LLM.call(AgentSettings.vision_model(), messages, trace: vision_trace()) do
          {:ok, raw} when is_binary(raw) and raw != "" ->
            parse_sentences(raw)

          other ->
            {:error, "vision_call_failed: #{inspect(other)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── vision JSON parsing ────────────────────────────────────────────────

  # Strip ``` fences a chatty model may emit even when told not to.
  defp parse_sentences(raw) do
    body = strip_fences(raw)

    case Jason.decode(body) do
      {:ok, %{"sentences" => list}} when is_list(list) ->
        cleaned =
          list
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if cleaned == [], do: {:empty, "no_text"}, else: {:ok, cleaned}

      _ ->
        {:error, "vision_json_invalid: " <> String.slice(body, 0, 200)}
    end
  end

  defp strip_fences(s) do
    s
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/, "")
    |> String.replace(~r/```\z/, "")
    |> String.trim()
  end

  # ── image encode (inlined; mirrors ExtractContent.scale_and_encode/1) ──

  defp scale_and_encode(path) do
    cond do
      not File.exists?(path) ->
        {:error, "image_missing: " <> Path.basename(path)}

      true ->
        tmp = "/tmp/dmh_ai_gettext_#{System.unique_integer([:positive])}.jpg"

        try do
          {_, code} =
            System.cmd("magick",
              [path, "-resize", "#{@resize_max_dim}x#{@resize_max_dim}>", "-quality", "85", tmp],
              stderr_to_stdout: true)

          if code == 0 and File.exists?(tmp) do
            case File.read(tmp) do
              {:ok, data} -> {:ok, Base.encode64(data)}
              {:error, r} -> {:error, "resize_read_failed: #{r}"}
            end
          else
            fallback_read(path)
          end
        rescue
          _ -> fallback_read(path)
        after
          File.rm(tmp)
        end
    end
  end

  defp fallback_read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, Base.encode64(data)}
      {:error, r} -> {:error, "image_read_failed: #{r}"}
    end
  end

  # ── persistence ────────────────────────────────────────────────────────

  defp finalize_with_payload(session_id, user_id, original_content, gettext_payload, fallback_text) do
    {:ok, user_ts} =
      UserAgentMessages.append(session_id, user_id, %{
        role: "user",
        content: original_content,
        kind: "command"
      })

    {:ok, _} =
      UserAgentMessages.append(session_id, user_id, %{
        role: "assistant",
        content: fallback_text,
        kind: "gettext",
        gettext: gettext_payload
      })

    {:handled, user_ts}
  end

  # Fallback `content` text — what shows when a FE renderer doesn't
  # know the `gettext:` field (e.g. polling clients on an old build).
  # The structured FE replaces this with the per-sentence layout.
  defp compose_fallback_text(per_image, sentences) do
    ok_count = Enum.count(per_image, &(&1.status == "ok"))
    err_count = Enum.count(per_image, &(&1.status == "error"))
    n = length(sentences)

    cond do
      n == 0 and err_count > 0 ->
        "Couldn't extract text from #{err_count} image(s)."

      n == 0 ->
        "No text found in the attached image(s)."

      true ->
        "Extracted #{n} sentence(s) from #{ok_count} image(s)." <>
          if(err_count > 0, do: " (#{err_count} image(s) errored.)", else: "")
    end
  end

  # ── trace + small utilities ────────────────────────────────────────────

  defp vision_trace do
    %{
      origin: "confidant",
      path: "Commands.Pipelines.Gettext.extract_one",
      role: "Gettext",
      phase: "vision_ocr",
      session_id: nil,
      user_id: nil,
      tier: :vision
    }
  end

  defp lookup_user_email(user_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]
    case query!(DmhAi.Repo, "SELECT email FROM users WHERE id=?", [user_id]).rows do
      [[email]] when is_binary(email) -> email
      _ -> ""
    end
  end
end
