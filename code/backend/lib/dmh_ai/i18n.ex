# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.I18n do
  @moduledoc """
  Tiny translation dictionary for user-visible labels produced by the
  runtime (not by the assistant / summariser — those emit in the user's
  language directly via LLM prompts).

  Languages currently shipped: en (source), de, vi, es, fr, ja.
  Other languages fall back to the en source automatically.

  Usage:
      DmhAi.I18n.t("llm_error", "vi", %{reason: "timeout"})
      => "Lỗi LLM: timeout"
  """

  @default_lang "en"

  # Keys are snake_case stable identifiers. Each value map: lang → template.
  # Placeholders use %{name} — substituted by bindings at call time.
  @messages %{
    "llm_error" => %{
      "en" => "LLM error: %{reason}",
      "de" => "LLM-Fehler: %{reason}",
      "vi" => "Lỗi LLM: %{reason}",
      "es" => "Error de LLM: %{reason}",
      "fr" => "Erreur LLM : %{reason}",
      "ja" => "LLM エラー: %{reason}"
    },
    "turn_cap_reached" => %{
      "en" => "I've reached the per-turn tool-call cap (%{max}). Let me know if you'd like me to continue.",
      "de" => "Ich habe das Tool-Aufruf-Limit pro Zug erreicht (%{max}). Sag Bescheid, wenn ich weitermachen soll.",
      "vi" => "Tôi đã đạt giới hạn gọi công cụ mỗi lượt (%{max}). Hãy cho tôi biết nếu bạn muốn tôi tiếp tục.",
      "es" => "He alcanzado el límite de llamadas a herramientas por turno (%{max}). Avísame si quieres que continúe.",
      "fr" => "J'ai atteint la limite d'appels d'outils par tour (%{max}). Dites-moi si vous voulez que je continue.",
      "ja" => "1ターンあたりのツール呼び出し上限 (%{max}) に達しました。続行する場合はお知らせください。"
    }
  }

  @doc """
  Translate `key` into `lang`, interpolating `%{name}` placeholders from `bindings`.
  Falls back to English then to the raw key if neither is available.
  """
  @spec t(String.t(), String.t() | nil, map()) :: String.t()
  def t(key, lang \\ @default_lang, bindings \\ %{})

  def t(key, lang, bindings) when is_binary(key) do
    lang = lang || @default_lang

    template =
      get_in(@messages, [key, lang]) ||
      get_in(@messages, [key, @default_lang]) ||
      key

    interpolate(template, bindings)
  end

  @doc "Language codes we ship built-in translations for."
  @spec supported_langs() :: [String.t()]
  def supported_langs, do: ["en", "de", "vi", "es", "fr", "ja"]

  @doc "All known keys (for coverage tests)."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@messages)

  # ─── private ────────────────────────────────────────────────────────────

  defp interpolate(template, bindings) when bindings == %{}, do: template
  defp interpolate(template, bindings) do
    Enum.reduce(bindings, template, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end
end
