# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Tagger do
  @moduledoc """
  Auto-tagger for KB ingest. One LLM call per source returns 3–10
  free-form lowercase labels (platform names, technical concepts,
  document type). Cap enforced post-hoc; truncates to 10 if the model
  returns more.

  Uses `oracleModel` by default (cheap, fast). Override via
  `kbTaggerModel` setting.

  Test hook: `Application.put_env(:dmh_ai, :__tagger_stub__, fn body -> ["tag1", "tag2"] end)`.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Agent.LLM
  require Logger

  @max_tags 10
  @body_excerpt_chars 4_000

  @spec tag(String.t(), map()) :: [String.t()]
  def tag(body, meta \\ %{}) when is_binary(body) and is_map(meta) do
    case Application.get_env(:dmh_ai, :__tagger_stub__) do
      stub when is_function(stub, 1) ->
        stub.(body) |> sanitize()

      _ ->
        do_tag(body, meta)
    end
  end

  defp do_tag(body, meta) do
    excerpt = String.slice(body, 0, @body_excerpt_chars)
    model   = tagger_model()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user",   content: excerpt}
    ]

    trace = %{
      origin: "system", path: "VectorDB.Tagger.tag",
      role: "KbTagger", phase: "tag",
      session_id: Map.get(meta, :session_id),
      user_id:    Map.get(meta, :user_id),
      tier:       :swift
    }

    case LLM.call(model, messages, options: %{temperature: 0.0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        parse_tags(text)

      _ ->
        Logger.warning("[Tagger] LLM call failed; storing source with no tags")
        []
    end
  rescue
    e ->
      Logger.warning("[Tagger] exception: #{Exception.message(e)}")
      []
  end

  defp tagger_model do
    case AgentSettings.model_for("kbTaggerModel") do
      "" -> AgentSettings.oracle_model()
      m  -> m
    end
  end

  defp system_prompt do
    """
    You are a tag extractor. Given a document body, return between 3 and #{@max_tags} short, lowercase, free-form tags that describe its subject.

    Rules:
    - Tags are platform/product names, technical concepts, or document type.
    - One word or hyphenated; no spaces, no punctuation.
    - Lowercase only.
    - Output ONLY a JSON array of strings. No prose, no markdown fences.

    Example output: ["bitrix24", "webhook", "oauth", "api-reference"]
    """
  end

  defp parse_tags(text) do
    cleaned =
      text
      |> String.trim()
      |> strip_code_fence()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) -> sanitize(list)
      _ -> []
    end
  end

  defp strip_code_fence(s) do
    s
    |> String.replace(~r/^```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  defp sanitize(list) when is_list(list) do
    list
    |> Enum.map(&to_clean_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_tags)
  end

  defp sanitize(_), do: []

  defp to_clean_tag(s) when is_binary(s) do
    s
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-]+/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
  end

  defp to_clean_tag(_), do: ""
end
