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
    },
    # Duolang lesson-panel fallbacks — the plain-text stand-in on a
    # kind="lesson" message, for clients that cannot render the panel.
    # Rendered in the LEARNER's own language, not the target language.
    "lesson_recall" => %{
      "en" => "Review: %{n} item(s).",
      "de" => "Wiederholung: %{n} Eintrag/Einträge.",
      "vi" => "Ôn tập: %{n} mục.",
      "es" => "Repaso: %{n} elemento(s).",
      "fr" => "Révision : %{n} élément(s).",
      "ja" => "復習: %{n} 件"
    },
    "lesson_read" => %{
      "en" => "A short passage about %{topic}.",
      "de" => "Ein kurzer Text über %{topic}.",
      "vi" => "Một đoạn ngắn về %{topic}.",
      "es" => "Un texto breve sobre %{topic}.",
      "fr" => "Un court texte sur %{topic}.",
      "ja" => "%{topic} についての短い文章"
    },
    "lesson_check" => %{
      "en" => "%{n} question(s) about the passage.",
      "de" => "%{n} Frage(n) zum Text.",
      "vi" => "%{n} câu hỏi về đoạn văn.",
      "es" => "%{n} pregunta(s) sobre el texto.",
      "fr" => "%{n} question(s) sur le texte.",
      "ja" => "本文についての質問 %{n} 件"
    },
    "lesson_speak" => %{
      "en" => "Read %{n} line(s) aloud.",
      "de" => "Lies %{n} Zeile(n) laut vor.",
      "vi" => "Đọc to %{n} dòng.",
      "es" => "Lee %{n} línea(s) en voz alta.",
      "fr" => "Lis %{n} ligne(s) à voix haute.",
      "ja" => "%{n} 行を音読してください"
    },
    "lesson_takeaway" => %{
      "en" => "That's the session.",
      "de" => "Das war die Lektion.",
      "vi" => "Buổi học kết thúc.",
      "es" => "Fin de la sesión.",
      "fr" => "Fin de la séance.",
      "ja" => "セッションは以上です"
    },
    # What the tutor SAYS at each micro-step. The learner reads these in
    # the chat, in their own language; the stage above holds whatever they
    # are being asked about.
    "say_recall" => %{
      "en" => "How do you say “%{prompt}” in %{lang}?",
      "de" => "Wie sagt man „%{prompt}“ auf %{lang}?",
      "vi" => "“%{prompt}” trong tiếng %{lang} nói thế nào?",
      "es" => "¿Cómo se dice «%{prompt}» en %{lang}?",
      "fr" => "Comment dit-on « %{prompt} » en %{lang} ?",
      "ja" => "「%{prompt}」は%{lang}で何と言いますか？"
    },
    "say_recall_back" => %{
      "en" => "You've met this one before — “%{prompt}”.",
      "de" => "Das kennst du schon — „%{prompt}“.",
      "vi" => "Bạn đã gặp từ này rồi — “%{prompt}”.",
      "es" => "Ya viste esta — «%{prompt}».",
      "fr" => "Tu as déjà vu celui-ci — « %{prompt} ».",
      "ja" => "これは前に出てきました —「%{prompt}」"
    },
    "say_read" => %{
      "en" => "Here's today's passage. Read it through — tap any line to hear it.",
      "de" => "Hier ist der Text für heute. Lies ihn durch — tippe eine Zeile an, um sie zu hören.",
      "vi" => "Đây là đoạn văn hôm nay. Đọc hết một lượt — nhấn vào dòng bất kỳ để nghe.",
      "es" => "Aquí está el texto de hoy. Léelo entero: toca cualquier línea para oírla.",
      "fr" => "Voici le texte du jour. Lis-le en entier — touche une ligne pour l'écouter.",
      "ja" => "今日の文章です。通して読んでください。行をタップすると音が出ます。"
    },
    "say_check_fallback" => %{
      "en" => "What was this passage about?",
      "de" => "Worum ging es in diesem Text?",
      "vi" => "Đoạn văn này nói về điều gì?",
      "es" => "¿De qué trataba este texto?",
      "fr" => "De quoi parlait ce texte ?",
      "ja" => "この文章は何についてでしたか？"
    },
    "brief_go" => %{
      "en" => "Great — let's go!"
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
