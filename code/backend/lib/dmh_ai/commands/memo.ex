# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Memo do
  @moduledoc """
  `/memo <content>` runtime command — saves one plaintext memo into
  the per-user `memos.db` store.

  Save flow:
    1. Persist the user message synchronously with `kind="command"`
       so `user_ts` returns immediately for FE optimistic-render
       dedup. The kind tag also keeps the message out of LLM context
       (it's audit log, not conversation).
    2. A background `Task.Supervisor` child indexes the memo via
       `DmhAi.Kb.index/5` (plaintext, FTS + trigram + spellfix + vec).
    3. A static "Memo saved." ack lands immediately as
       `kind="command_ack"` — no LLM and no embedder round-trip on the
       request path. The ack is keyed off the FE-supplied `lang`.

  Retrieval is not slash-driven: `DmhAi.Kb.Query` fans out over
  facts.db / memos.db for every user message and injects the top hits
  as the `<user_memos>` block.

  Safety: if the background index task crashes, the worst case is a
  saved memo that isn't yet searchable — never an unanswered message
  in the LLM's context.

  See arch_wiki/dmh_ai/facts_memos.md and specs/commands.md.
  """

  alias DmhAi.Agent.UserAgentMessages
  alias DmhAi.Commands
  require Logger

  # ─── Static translation table ─────────────────────────────────────────────
  #
  # Mirrors the FE i18n dictionary in `code/js/core.js` for the same
  # five locales. All strings deliberately short — these surface as
  # the synthetic assistant ack right after a `/memo` save, so they
  # need to read clean and on-tone, not LLM-fluffy.

  @t %{
    "en" => %{saved: "Memo saved.", usage: "Usage: `/memo <content to save>`"},
    "vi" => %{saved: "Đã lưu ghi chú.", usage: "Cách dùng: `/memo <nội dung cần lưu>`"},
    "de" => %{saved: "Notiz gespeichert.", usage: "Nutzung: `/memo <Inhalt zum Speichern>`"},
    "es" => %{saved: "Nota guardada.", usage: "Uso: `/memo <contenido a guardar>`"},
    "fr" => %{saved: "Note enregistrée.", usage: "Utilisation : `/memo <contenu à enregistrer>`"}
  }

  # ─── Public API ───────────────────────────────────────────────────────────

  @spec run(String.t(), String.t(), String.t(), String.t(), String.t()) :: {:handled, non_neg_integer()}
  def run(arg, original_content, session_id, user_id, lang \\ "en") do
    arg = String.trim(arg)
    lang = normalize_lang(lang)

    if arg == "" do
      # Empty arg → static usage hint in the user's locale.
      Commands.append_command_pair(session_id, user_id, original_content,
        t(lang, :usage))
    else
      # The ack renders immediately (no LLM, no embedder round-trip). The
      # memo is indexed into memos.db (plaintext) in a background Task — the
      # embed inside Kb.index is the only slow part and the lexical index is
      # written regardless. See arch_wiki/dmh_ai/facts_memos.md.
      {:ok, user_ts} = UserAgentMessages.append(session_id, user_id, %{
        role: "user",
        content: original_content,
        kind: "command"
      })

      Task.Supervisor.start_child(DmhAi.Agent.TaskSupervisor, fn ->
        case DmhAi.Kb.index(DmhAi.MemosRepo, "memos", user_id, arg, "memo") do
          :error -> Logger.warning("[Memo] index failed user=#{user_id}")
          _ -> :ok
        end
      end)

      append_ack(session_id, user_id, t(lang, :saved))
      {:handled, user_ts}
    end
  end

  # ─── Ack rendering ────────────────────────────────────────────────────────

  defp append_ack(session_id, user_id, content) do
    UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: content,
      kind: "command_ack"
    })
  end

  # ─── Internal ─────────────────────────────────────────────────────────────

  # Translation accessor — falls through to English on any unknown
  # locale OR missing key. Tests check this fallthrough.
  defp t(lang, key) do
    locale = Map.get(@t, lang, @t["en"])
    Map.get(locale, key, Map.fetch!(@t["en"], key))
  end

  # Normalise a caller-supplied locale string to one we have in `@t`.
  # FE sends `I18n._lang` which is already in our supported set — but
  # be defensive: trimming, lowercasing, and falling back to English
  # for anything else means a malformed or unset value can never
  # crash the save path.
  defp normalize_lang(lang) when is_binary(lang) do
    case String.downcase(String.trim(lang)) do
      l when is_map_key(@t, l) -> l
      _ -> "en"
    end
  end

  defp normalize_lang(_), do: "en"
end
