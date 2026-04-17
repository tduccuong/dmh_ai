# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.WebSearch do
  @moduledoc """
  Confidant-specific web search helpers.

  `synthesize_results/1` compresses large raw search results into a fact-dense
  text before injecting into the master context.

  Search detection, query generation, and execution live in `Dmhai.Web.Search`.
  """

  alias Dmhai.Agent.{AgentSettings, LLM}
  require Logger

  @doc """
  Synthesize raw web search results into a compact fact-dense text.
  Used when the raw results exceed the synthesis threshold.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec synthesize_results(String.t()) :: {:ok, String.t()} | {:error, term()}
  def synthesize_results(raw_results) do
    model = AgentSettings.web_search_model()
    today = Date.to_string(Date.utc_today())

    prompt =
      "Today is #{today}. You are a neutral information extractor. " <>
        "Rewrite the following raw web search results into one coherent, compact text. Rules:\n" <>
        "- Preserve as much information as possible — do not drop facts\n" <>
        "- Highlight key facts as bullet points\n" <>
        "- Be concise: remove ads, navigation text, duplicates, and boilerplate\n" <>
        "- Fix any garbled text: insert missing spaces between words, numbers, and letters where clearly needed\n" <>
        "- Do NOT interpret, conclude, or answer any question — just present the facts as found\n" <>
        "- Do NOT reference any question or topic — treat the content as standalone\n\n" <>
        "Raw web results:\n#{raw_results}\n\nExtracted facts:"

    LLM.call(model, [%{role: "user", content: prompt}],
      options: %{temperature: 0, num_predict: 1500}
    )
  end
end
