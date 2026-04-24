# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.I18n do
  @moduledoc """
  Tiny translation dictionary for user-visible labels produced by the
  runtime (not by the assistant / summariser — those emit in the user's
  language directly via LLM prompts).

  Languages currently shipped: en (source), de, vi, es, fr, ja.
  Other languages fall back to the en source automatically.

  Usage:
      Dmhai.I18n.t("llm_error", "vi", %{reason: "timeout"})
      => "Lỗi LLM: timeout"
  """

  @default_lang "en"

  # Keys are snake_case stable identifiers. Each value map: lang → template.
  # Placeholders use %{name} — substituted by bindings at call time.
  @messages %{
    "no_new_activity" => %{
      "en" => "No new activity for **%{title}** since the last update.",
      "de" => "Keine neue Aktivität für **%{title}** seit dem letzten Update.",
      "vi" => "Không có hoạt động mới cho **%{title}** kể từ lần cập nhật trước.",
      "es" => "Sin actividad nueva para **%{title}** desde la última actualización.",
      "fr" => "Aucune nouvelle activité pour **%{title}** depuis la dernière mise à jour.",
      "ja" => "前回の更新以降、**%{title}** の新しい活動はありません。"
    },
    "summary_already_being_prepared" => %{
      "en" => "A progress update is already being prepared — it will appear in chat shortly.",
      "de" => "Ein Fortschrittsbericht wird bereits erstellt — er erscheint gleich im Chat.",
      "vi" => "Đang chuẩn bị bản cập nhật tiến độ — sẽ xuất hiện trong hộp chat ngay.",
      "es" => "Ya se está preparando una actualización de progreso — aparecerá en el chat en breve.",
      "fr" => "Une mise à jour de progression est déjà en préparation — elle apparaîtra dans le chat sous peu.",
      "ja" => "進捗の更新を準備中です — まもなくチャットに表示されます。"
    },
    "llm_error" => %{
      "en" => "LLM error: %{reason}",
      "de" => "LLM-Fehler: %{reason}",
      "vi" => "Lỗi LLM: %{reason}",
      "es" => "Error de LLM: %{reason}",
      "fr" => "Erreur LLM : %{reason}",
      "ja" => "LLM エラー: %{reason}"
    },
    "llm_empty_response" => %{
      "en" => "LLM returned empty response.",
      "de" => "LLM hat eine leere Antwort zurückgegeben.",
      "vi" => "LLM trả về phản hồi rỗng.",
      "es" => "El LLM devolvió una respuesta vacía.",
      "fr" => "Le LLM a renvoyé une réponse vide.",
      "ja" => "LLM が空の応答を返しました。"
    },
    "turn_cap_reached" => %{
      "en" => "I've reached the per-turn tool-call cap (%{max}). Let me know if you'd like me to continue.",
      "de" => "Ich habe das Tool-Aufruf-Limit pro Zug erreicht (%{max}). Sag Bescheid, wenn ich weitermachen soll.",
      "vi" => "Tôi đã đạt giới hạn gọi công cụ mỗi lượt (%{max}). Hãy cho tôi biết nếu bạn muốn tôi tiếp tục.",
      "es" => "He alcanzado el límite de llamadas a herramientas por turno (%{max}). Avísame si quieres que continúe.",
      "fr" => "J'ai atteint la limite d'appels d'outils par tour (%{max}). Dites-moi si vous voulez que je continue.",
      "ja" => "1ターンあたりのツール呼び出し上限 (%{max}) に達しました。続行する場合はお知らせください。"
    },
    # System-error variants. `%{reason}` is the humanised cause
    # (from UserAgent.humanize_system_error/1). `%{task_num}` is the
    # per-session `(N)` that the runtime auto-paused; omitted from
    # the "no active task" variant because there's nothing to resume.
    "system_error_paused" => %{
      "en" => "Sorry — %{reason}. I've paused task (%{task_num}) so no work is lost. Let me know once it's resolved and I'll resume.",
      "de" => "Entschuldigung — %{reason}. Ich habe Aufgabe (%{task_num}) pausiert, damit keine Arbeit verloren geht. Sag Bescheid, wenn das Problem behoben ist, dann nehme ich sie wieder auf.",
      "vi" => "Xin lỗi — %{reason}. Tôi đã tạm dừng task (%{task_num}) để không mất tiến độ. Hãy cho tôi biết khi sự cố đã được giải quyết để tôi tiếp tục.",
      "es" => "Perdón — %{reason}. He pausado la tarea (%{task_num}) para no perder el avance. Avísame cuando esté resuelto y la reanudaré.",
      "fr" => "Désolé — %{reason}. J'ai mis en pause la tâche (%{task_num}) pour ne rien perdre. Dites-moi quand c'est résolu et je reprendrai.",
      "ja" => "申し訳ありません — %{reason}。作業が失われないようタスク (%{task_num}) を一時停止しました。解決したらお知らせください、再開します。"
    },
    "system_error_no_active_task" => %{
      "en" => "Sorry — %{reason}. Please let me know once it's resolved and I'll try again.",
      "de" => "Entschuldigung — %{reason}. Bitte sag Bescheid, wenn das Problem behoben ist, dann versuche ich es erneut.",
      "vi" => "Xin lỗi — %{reason}. Hãy cho tôi biết khi sự cố đã được giải quyết để tôi thử lại.",
      "es" => "Perdón — %{reason}. Avísame cuando esté resuelto y lo intentaré de nuevo.",
      "fr" => "Désolé — %{reason}. Dites-moi quand c'est résolu et je réessaierai.",
      "ja" => "申し訳ありません — %{reason}。解決したらお知らせください、再試行します。"
    },
    # Humanised cause strings — short phrase inserted as %{reason}
    # above. Keep them lower-case sentence fragments (the outer
    # template starts with "Sorry — ").
    "system_error_cause_keys_exhausted" => %{
      "en" => "all our AI-service API keys have been exhausted",
      "de" => "alle API-Schlüssel für den KI-Dienst sind aufgebraucht",
      "vi" => "tất cả các API key cho dịch vụ AI đã hết",
      "es" => "todas nuestras claves de API del servicio de IA se han agotado",
      "fr" => "toutes nos clés API du service IA sont épuisées",
      "ja" => "AI サービスの API キーがすべて使い切られました"
    },
    "system_error_cause_rate_limited" => %{
      "en" => "the AI service is rate-limiting our requests right now",
      "de" => "der KI-Dienst begrenzt gerade unsere Anfragen (Rate-Limit)",
      "vi" => "dịch vụ AI đang giới hạn tốc độ yêu cầu của chúng tôi",
      "es" => "el servicio de IA está limitando nuestras solicitudes en este momento",
      "fr" => "le service IA limite actuellement nos requêtes",
      "ja" => "AI サービスが現在リクエストのレート制限中です"
    },
    "system_error_cause_server_error" => %{
      "en" => "the AI service returned a server error",
      "de" => "der KI-Dienst hat einen Serverfehler zurückgegeben",
      "vi" => "dịch vụ AI trả về lỗi máy chủ",
      "es" => "el servicio de IA devolvió un error del servidor",
      "fr" => "le service IA a renvoyé une erreur serveur",
      "ja" => "AI サービスがサーバーエラーを返しました"
    },
    "system_error_cause_timeout" => %{
      "en" => "the AI service timed out while responding",
      "de" => "die Anfrage an den KI-Dienst ist beim Antworten abgelaufen",
      "vi" => "dịch vụ AI phản hồi quá chậm (timeout)",
      "es" => "el servicio de IA agotó el tiempo de espera al responder",
      "fr" => "le service IA a dépassé le délai d'attente de la réponse",
      "ja" => "AI サービスの応答がタイムアウトしました"
    },
    "system_error_cause_generic" => %{
      "en" => "we hit a transient issue talking to the AI service",
      "de" => "es gab ein vorübergehendes Problem bei der Kommunikation mit dem KI-Dienst",
      "vi" => "gặp sự cố tạm thời khi kết nối với dịch vụ AI",
      "es" => "tuvimos un problema transitorio al comunicarnos con el servicio de IA",
      "fr" => "nous avons rencontré un problème temporaire avec le service IA",
      "ja" => "AI サービスとの通信で一時的な問題が発生しました"
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
