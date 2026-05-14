# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Memo do
  @moduledoc """
  `/memo <content>` runtime command — write-only save against the
  user's per-user memo store.

  Querying is conversational, not slash-driven:
    * Assistant calls the `fetch_memo` tool from its catalog when a
      question matches stored memo content.
    * Confidant runs an automatic memo-retrieval pre-step before each
      LLM call.

  Save flow:
    1. Persist the user message synchronously with `kind="command"`
       so `user_ts` can return immediately for FE optimistic-render
       dedup. The kind tag also keeps the message out of LLM context
       (it's audit log, not conversation).
    2. Background `Task.Supervisor` child runs `VectorDB.ingest/2`.
       The ack lands as `kind="command_ack"` once the ingest
       completes, or as a localized error if it fails.

  **No LLM call on the `/memo` path.** The ack uses a static
  translation table keyed by the FE-supplied `lang` ("Memo saved." +
  short error variants in 5 supported languages). This was previously
  a `Swift.localize` round-trip; dropping it removes a 0.5–3 s wait
  per save and cuts the call dependency on the embedder pool.

  Safety: if the background task crashes mid-ingest, the worst case
  is a stuck `kind="command"` message in scrollback — never an
  unanswered message in the LLM's context.

  See specs/commands.md.
  """

  alias DmhAi.Agent.{UserAgent, UserAgentMessages}
  alias DmhAi.Commands
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder
  require Logger

  # ─── Static translation table ─────────────────────────────────────────────
  #
  # Mirrors the FE i18n dictionary in `code/js/core.js` for the same
  # five locales. All strings deliberately short — these surface as
  # the synthetic assistant ack right after a `/memo` save, so they
  # need to read clean and on-tone, not LLM-fluffy.

  @t %{
    "en" => %{
      saved: "Memo saved.",
      usage: "Usage: `/memo <content to save>`",
      err_no_accounts: "Couldn't save: no embedding accounts configured. Add one in System Settings → Pools.",
      err_throttled:   "Couldn't save: all embedding accounts are rate-limited. Try again in %{secs}s.",
      err_unknown_pool: "Couldn't save: the embedding pool isn't configured. Check the kbEmbeddingModel setting.",
      err_bad_pool_id: "Couldn't save: the kbEmbeddingModel setting is malformed.",
      err_memo_key:    "Couldn't save: the memo key for your account is not available right now.",
      err_legacy_wrap: "Please sign out and sign back in — this account's memo encryption needs a one-time upgrade that only your password can complete.",
      err_index_failed: "Memo saved, but couldn't index it for search (%{detail}). It's stored on disk; retrieval may not find it until the embedder is back.",
      err_other:       "Couldn't save: %{detail}"
    },
    "vi" => %{
      saved: "Đã lưu ghi chú.",
      usage: "Cách dùng: `/memo <nội dung cần lưu>`",
      err_no_accounts: "Không lưu được: chưa cấu hình tài khoản embedding. Thêm trong Cài đặt hệ thống → Pools.",
      err_throttled:   "Không lưu được: tất cả tài khoản embedding đang bị giới hạn. Thử lại sau %{secs}s.",
      err_unknown_pool: "Không lưu được: pool embedding chưa được cấu hình. Kiểm tra mục kbEmbeddingModel.",
      err_bad_pool_id: "Không lưu được: cài đặt kbEmbeddingModel không hợp lệ.",
      err_memo_key:    "Không lưu được: khóa ghi chú của bạn hiện không khả dụng.",
      err_legacy_wrap: "Vui lòng đăng xuất rồi đăng nhập lại — tài khoản này cần một bước nâng cấp mã hóa một lần, chỉ mật khẩu của bạn mới hoàn tất được.",
      err_index_failed: "Đã lưu ghi chú, nhưng không lập chỉ mục được (%{detail}). Ghi chú đã có trên đĩa; tìm kiếm có thể chưa thấy cho đến khi bộ nhúng hoạt động lại.",
      err_other:       "Không lưu được: %{detail}"
    },
    "de" => %{
      saved: "Notiz gespeichert.",
      usage: "Nutzung: `/memo <Inhalt zum Speichern>`",
      err_no_accounts: "Speichern fehlgeschlagen: keine Embedding-Konten konfiguriert. Bitte in den Systemeinstellungen → Pools hinzufügen.",
      err_throttled:   "Speichern fehlgeschlagen: alle Embedding-Konten sind rate-limitiert. In %{secs}s erneut versuchen.",
      err_unknown_pool: "Speichern fehlgeschlagen: der Embedding-Pool ist nicht konfiguriert. Prüfe die Einstellung kbEmbeddingModel.",
      err_bad_pool_id: "Speichern fehlgeschlagen: die Einstellung kbEmbeddingModel ist fehlerhaft.",
      err_memo_key:    "Speichern fehlgeschlagen: der Notiz-Schlüssel für dein Konto ist gerade nicht verfügbar.",
      err_legacy_wrap: "Bitte abmelden und erneut anmelden — die Notiz-Verschlüsselung dieses Kontos braucht ein einmaliges Upgrade, das nur mit deinem Passwort möglich ist.",
      err_index_failed: "Notiz gespeichert, aber Indexierung fehlgeschlagen (%{detail}). Sie ist auf der Festplatte abgelegt; die Suche findet sie eventuell erst, wenn der Embedder wieder läuft.",
      err_other:       "Speichern fehlgeschlagen: %{detail}"
    },
    "es" => %{
      saved: "Nota guardada.",
      usage: "Uso: `/memo <contenido a guardar>`",
      err_no_accounts: "No se pudo guardar: no hay cuentas de embedding configuradas. Añade una en Configuración del sistema → Pools.",
      err_throttled:   "No se pudo guardar: todas las cuentas de embedding están limitadas. Reintenta en %{secs}s.",
      err_unknown_pool: "No se pudo guardar: el pool de embedding no está configurado. Revisa el ajuste kbEmbeddingModel.",
      err_bad_pool_id: "No se pudo guardar: el ajuste kbEmbeddingModel está mal formado.",
      err_memo_key:    "No se pudo guardar: la clave de tus notas no está disponible ahora mismo.",
      err_legacy_wrap: "Cierra sesión y vuelve a iniciarla — el cifrado de notas de esta cuenta necesita una actualización única que solo tu contraseña puede completar.",
      err_index_failed: "Nota guardada, pero no se pudo indexar para búsqueda (%{detail}). Está en disco; la búsqueda puede no encontrarla hasta que el embedder vuelva a estar disponible.",
      err_other:       "No se pudo guardar: %{detail}"
    },
    "fr" => %{
      saved: "Note enregistrée.",
      usage: "Utilisation : `/memo <contenu à enregistrer>`",
      err_no_accounts: "Échec de l'enregistrement : aucun compte d'embedding configuré. Ajoutez-en un dans Paramètres système → Pools.",
      err_throttled:   "Échec de l'enregistrement : tous les comptes d'embedding sont limités. Réessayez dans %{secs}s.",
      err_unknown_pool: "Échec de l'enregistrement : le pool d'embedding n'est pas configuré. Vérifiez le paramètre kbEmbeddingModel.",
      err_bad_pool_id: "Échec de l'enregistrement : le paramètre kbEmbeddingModel est mal formé.",
      err_memo_key:    "Échec de l'enregistrement : la clé de tes notes n'est pas disponible pour le moment.",
      err_legacy_wrap: "Déconnecte-toi puis reconnecte-toi — le chiffrement des notes de ce compte nécessite une mise à niveau unique que seul ton mot de passe peut effectuer.",
      err_index_failed: "Note enregistrée, mais l'indexation a échoué (%{detail}). Elle est sur disque ; la recherche peut ne pas la trouver tant que l'embedder n'est pas revenu.",
      err_other:       "Échec de l'enregistrement : %{detail}"
    }
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
      # ── Synchronous critical path ────────────────────────────────────────
      # Per specs/commands.md § /memo, the ack is rendered immediately —
      # no LLM call AND no embedder round-trip. The synchronous work is:
      #
      #   1. persist user msg (kind="command")           — DB write
      #   2. ensure_memo_key (cached after first call)   — typically instant
      #   3. ingest_memo_async (chunk + encrypt + meta)  — DB writes only
      #   4. append "Memo saved." ack (kind="command_ack")
      #
      # The slow embedder HTTP call happens in a background Task that
      # populates `kb_vec_memo` later; until it completes the memo isn't
      # retrievable via `fetch_memo`, but it IS durable on disk.
      {:ok, user_ts} = UserAgentMessages.append(session_id, user_id, %{
        role: "user",
        content: original_content,
        kind: "command"
      })

      ack_result = save_sync(arg, user_id)

      append_ack(session_id, user_id, ack_message(ack_result, lang))

      # Spawn the background embed phase only when the sync save
      # actually persisted chunk rows.
      case ack_result do
        {:ok, %{chunks: chunks}} when chunks != [] ->
          Task.Supervisor.start_child(DmhAi.Agent.TaskSupervisor, fn ->
            embed_async(chunks, session_id, user_id, lang)
          end)

        _ ->
          :ok
      end

      {:handled, user_ts}
    end
  end

  # Phase 1 (sync): everything except the embedding HTTP call. Returns
  # `{:ok, %{chunks: [...]}}` with the chunk records the background
  # embed task will fill in, or a tagged `{:error, reason}` for the
  # ack to render against.
  defp save_sync(text, user_id) do
    case UserAgent.ensure_memo_key(user_id) do
      {:ok, mmk} ->
        attrs = %{
          scope:       :memo,
          org_id:      DmhAi.Orgs.for_user(user_id),
          user_id:     user_id,
          source_kind: "text",
          source_ref:  sha256(text),
          title:       nil,
          memo_key:    mmk,
          body:        text
        }

        VectorDB.ingest_memo_async(attrs)

      # Legacy V1 wrap — needs login to migrate. Bubble the reason up
      # so the ack renders the friendly "sign out and back in" copy.
      {:error, :legacy_v1} ->
        {:error, :legacy_v1}

      {:error, _reason} = err ->
        err
    end
  end

  # Phase 2 (background): embed each chunk's plaintext via the
  # configured embedder pool, then `attach_memo_embedding` for each.
  # On embed failure we append a follow-up assistant message so the
  # user sees that retrieval will be unavailable for this memo. Rare
  # path; the encrypted chunk is durable on disk regardless.
  defp embed_async(chunks, session_id, user_id, lang) do
    plaintexts = Enum.map(chunks, & &1.plaintext)

    case Embedder.embed_batch(plaintexts) do
      {:ok, embeddings} ->
        Enum.zip(chunks, embeddings)
        |> Enum.each(fn {%{meta_id: id}, vec} ->
          case VectorDB.attach_memo_embedding(id, vec) do
            :ok -> :ok
            {:error, reason} ->
              Logger.warning("[Memo] attach_memo_embedding failed user=#{user_id} meta_id=#{id}: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.warning("[Memo] embed_async failed user=#{user_id}: #{inspect(reason)}")
        append_ack(session_id, user_id, indexing_failed_message(lang, reason))
    end
  rescue
    e ->
      Logger.error("[Memo] embed worker crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
  end

  # ─── Ack rendering ────────────────────────────────────────────────────────

  defp ack_message({:ok, _info},               lang), do: t(lang, :saved)
  defp ack_message({:error, :legacy_v1},       lang), do: t(lang, :err_legacy_wrap)
  defp ack_message({:error, :memo_key_unavailable}, lang), do: t(lang, :err_memo_key)
  defp ack_message({:error, reason},           lang), do: error_text(lang, reason)

  defp indexing_failed_message(lang, reason) do
    t(lang, :err_index_failed)
    |> String.replace("%{detail}", inspect(reason, limit: 80))
  end

  defp append_ack(session_id, user_id, content) do
    UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: content,
      kind: "command_ack"
    })
  end

  # ─── Internal ─────────────────────────────────────────────────────────────

  defp sha256(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  # Map ingest errors to short i18n keys; substitutes %{secs} / %{detail}
  # placeholders for variable bits. Unknown errors fall through to the
  # generic `:err_other` template with `inspect/1` detail — preserves
  # operator diagnostic value without silently swallowing failures.
  defp error_text(lang, {:all_throttled, 0}),
    do: t(lang, :err_no_accounts)

  defp error_text(lang, {:all_throttled, retry_ms}) when is_integer(retry_ms) and retry_ms > 0,
    do: t(lang, :err_throttled) |> String.replace("%{secs}", Integer.to_string(div(retry_ms + 999, 1000)))

  defp error_text(lang, :unknown_pool),
    do: t(lang, :err_unknown_pool)

  defp error_text(lang, :invalid_format),
    do: t(lang, :err_bad_pool_id)

  defp error_text(lang, :memo_key_unavailable),
    do: t(lang, :err_memo_key)

  defp error_text(lang, reason),
    do: t(lang, :err_other) |> String.replace("%{detail}", inspect(reason, limit: 80))

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
