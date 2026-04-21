# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.I18n do
  @moduledoc """
  Tiny translation dictionary for user-visible labels produced by the
  runtime (not by the worker / Assistant / summarizer — those emit in
  the user's language directly via LLM prompts).

  Languages currently shipped: en (source), de, vi, es, fr, ja.
  Other languages fall back to the en source automatically.

  Usage:
      Dmhai.I18n.t("blocked_label", "vi", %{reason: "api down"})
      => "Bị chặn: api down"
  """

  @default_lang "en"

  # Keys are snake_case stable identifiers. Each value map: lang → template.
  # Placeholders use %{name} — substituted by bindings at call time.
  @messages %{
    "blocked_label" => %{
      "en" => "Blocked: %{reason}",
      "de" => "Blockiert: %{reason}",
      "vi" => "Bị chặn: %{reason}",
      "es" => "Bloqueado: %{reason}",
      "fr" => "Bloqué : %{reason}",
      "ja" => "ブロック済み: %{reason}"
    },
    "notify_done" => %{
      "en" => "✓ %{title}",
      "de" => "✓ %{title}",
      "vi" => "✓ %{title}",
      "es" => "✓ %{title}",
      "fr" => "✓ %{title}",
      "ja" => "✓ %{title}"
    },
    "notify_blocked" => %{
      "en" => "🔴 %{title} — blocked",
      "de" => "🔴 %{title} — blockiert",
      "vi" => "🔴 %{title} — bị chặn",
      "es" => "🔴 %{title} — bloqueado",
      "fr" => "🔴 %{title} — bloqué",
      "ja" => "🔴 %{title} — ブロック済み"
    },
    "notify_progress" => %{
      "en" => "↻ %{title}",
      "de" => "↻ %{title}",
      "vi" => "↻ %{title}",
      "es" => "↻ %{title}",
      "fr" => "↻ %{title}",
      "ja" => "↻ %{title}"
    },
    "worker_exited_no_signal" => %{
      "en" => "Worker process exited without calling signal().",
      "de" => "Worker-Prozess beendet ohne signal() aufzurufen.",
      "vi" => "Tiến trình worker đã thoát mà không gọi signal().",
      "es" => "El proceso del worker terminó sin llamar a signal().",
      "fr" => "Le processus du worker s'est terminé sans appeler signal().",
      "ja" => "worker プロセスは signal() を呼び出さずに終了しました。"
    },
    "task_cancelled_by_user" => %{
      "en" => "Job cancelled by user.",
      "de" => "Auftrag vom Benutzer abgebrochen.",
      "vi" => "Công việc đã bị huỷ bởi người dùng.",
      "es" => "Tarea cancelada por el usuario.",
      "fr" => "Tâche annulée par l'utilisateur.",
      "ja" => "ユーザーによってジョブがキャンセルされました。"
    },
    "worker_orphaned" => %{
      "en" => "Worker orphaned by app restart.",
      "de" => "Worker nach App-Neustart verwaist.",
      "vi" => "Worker bị gián đoạn do ứng dụng khởi động lại.",
      "es" => "Worker huérfano por reinicio de la aplicación.",
      "fr" => "Worker orphelin après redémarrage de l'application.",
      "ja" => "アプリの再起動により worker が孤立しました。"
    },
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
    "max_iter_reached" => %{
      "en" => "Max iterations (%{max}) reached without calling signal().",
      "de" => "Maximale Iterationsanzahl (%{max}) erreicht ohne signal() aufzurufen.",
      "vi" => "Đã đạt giới hạn số vòng lặp (%{max}) mà không gọi signal().",
      "es" => "Se alcanzó el máximo de iteraciones (%{max}) sin llamar a signal().",
      "fr" => "Nombre maximal d'itérations (%{max}) atteint sans appeler signal().",
      "ja" => "signal() を呼ばずに最大反復回数 (%{max}) に達しました。"
    },
    "worker_refused_signal" => %{
      "en" => "Worker refused to call signal after %{count} nudges. Last text: %{text}",
      "de" => "Worker hat signal nach %{count} Hinweisen nicht aufgerufen. Letzter Text: %{text}",
      "vi" => "Worker không chịu gọi signal sau %{count} lần nhắc. Văn bản cuối: %{text}",
      "es" => "El worker no llamó a signal tras %{count} avisos. Último texto: %{text}",
      "fr" => "Le worker a refusé d'appeler signal après %{count} rappels. Dernier texte : %{text}",
      "ja" => "%{count} 回の催促後も worker は signal を呼びませんでした。最後のテキスト: %{text}"
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
    "internal_error" => %{
      "en" => "An internal error occurred. I'll look into it and report back to you.",
      "de" => "Ein interner Fehler ist aufgetreten. Ich werde ihn untersuchen und Sie informieren.",
      "vi" => "Đã xảy ra lỗi nội bộ. Tôi sẽ xem xét và phản hồi lại cho bạn.",
      "es" => "Ocurrió un error interno. Lo investigaré y te informaré.",
      "fr" => "Une erreur interne s'est produite. Je vais l'examiner et vous en informer.",
      "ja" => "内部エラーが発生しました。調査して報告します。",
      "zh" => "发生了内部错误。我将进行调查并向您报告。",
      "ko" => "내부 오류가 발생했습니다. 조사 후 보고드리겠습니다.",
      "pt" => "Ocorreu um erro interno. Vou investigar e informar você."
    },
    "policy_violation" => %{
      "en" => "Repeated policy violation: %{reason}",
      "de" => "Wiederholter Regelverstoß: %{reason}",
      "vi" => "Vi phạm quy tắc lặp lại: %{reason}",
      "es" => "Violación de política repetida: %{reason}",
      "fr" => "Violation de politique répétée : %{reason}",
      "ja" => "ポリシー違反の繰り返し: %{reason}"
    },
    "task_not_found" => %{
      "en" => "No task found for id=%{id}.",
      "de" => "Kein Auftrag mit id=%{id} gefunden.",
      "vi" => "Không tìm thấy công việc với id=%{id}.",
      "es" => "No se encontró ninguna tarea con id=%{id}.",
      "fr" => "Aucune tâche trouvée pour id=%{id}.",
      "ja" => "id=%{id} のジョブは見つかりませんでした。"
    },
    "no_such_task" => %{
      "en" => "No such task.",
      "de" => "Diesen Auftrag gibt es nicht.",
      "vi" => "Không có công việc nào như vậy.",
      "es" => "No existe tal tarea.",
      "fr" => "Cette tâche n'existe pas.",
      "ja" => "該当するジョブはありません。"
    },
    "no_task_id" => %{
      "en" => "No task_id provided.",
      "de" => "Keine task_id angegeben.",
      "vi" => "Chưa cung cấp task_id.",
      "es" => "No se proporcionó task_id.",
      "fr" => "Aucun task_id fourni.",
      "ja" => "task_id が指定されていません。"
    },
    "bad_interval" => %{
      "en" => "intvl_sec must be > 0.",
      "de" => "intvl_sec muss > 0 sein.",
      "vi" => "intvl_sec phải lớn hơn 0.",
      "es" => "intvl_sec debe ser > 0.",
      "fr" => "intvl_sec doit être > 0.",
      "ja" => "intvl_sec は 0 より大きい必要があります。"
    },
    "task_status_rendered" => %{
      "en" => "Job **%{title}** — %{status}.\n\n%{result}",
      "de" => "Auftrag **%{title}** — %{status}.\n\n%{result}",
      "vi" => "Công việc **%{title}** — %{status}.\n\n%{result}",
      "es" => "Tarea **%{title}** — %{status}.\n\n%{result}",
      "fr" => "Tâche **%{title}** — %{status}.\n\n%{result}",
      "ja" => "ジョブ **%{title}** — %{status}。\n\n%{result}"
    },
    "status_done" => %{
      "en" => "done",
      "de" => "abgeschlossen",
      "vi" => "đã xong",
      "es" => "completada",
      "fr" => "terminée",
      "ja" => "完了"
    },
    "status_blocked" => %{
      "en" => "blocked",
      "de" => "blockiert",
      "vi" => "bị chặn",
      "es" => "bloqueada",
      "fr" => "bloquée",
      "ja" => "ブロック済み"
    },
    "status_cancelled" => %{
      "en" => "cancelled",
      "de" => "abgebrochen",
      "vi" => "đã huỷ",
      "es" => "cancelada",
      "fr" => "annulée",
      "ja" => "キャンセル済み"
    },
    "status_paused" => %{
      "en" => "paused",
      "de" => "pausiert",
      "vi" => "tạm dừng",
      "es" => "pausada",
      "fr" => "en pause",
      "ja" => "一時停止中"
    },
    "task_paused" => %{
      "en" => "Job **%{title}** has been paused. Resume it anytime.",
      "de" => "Auftrag **%{title}** wurde pausiert. Du kannst ihn jederzeit fortsetzen.",
      "vi" => "Công việc **%{title}** đã tạm dừng. Bạn có thể tiếp tục bất cứ lúc nào.",
      "es" => "La tarea **%{title}** ha sido pausada. Reanúdala cuando quieras.",
      "fr" => "La tâche **%{title}** a été mise en pause. Reprenez-la quand vous voulez.",
      "ja" => "ジョブ **%{title}** を一時停止しました。いつでも再開できます。"
    },
    "task_resumed" => %{
      "en" => "Job **%{title}** has been resumed.",
      "de" => "Auftrag **%{title}** wurde fortgesetzt.",
      "vi" => "Công việc **%{title}** đã được tiếp tục.",
      "es" => "La tarea **%{title}** ha sido reanudada.",
      "fr" => "La tâche **%{title}** a été reprise.",
      "ja" => "ジョブ **%{title}** を再開しました。"
    },
    "no_result" => %{
      "en" => "(no result)",
      "de" => "(kein Ergebnis)",
      "vi" => "(không có kết quả)",
      "es" => "(sin resultado)",
      "fr" => "(aucun résultat)",
      "ja" => "(結果なし)"
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
