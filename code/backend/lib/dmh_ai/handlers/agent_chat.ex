# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AgentChat do
  @moduledoc """
  POST /agent/chat — fire-and-forget entry point for a chat turn.

  The handler persists the user message with a BE-stamped `ts`, dispatches
  the turn to the UserAgent (which runs it asynchronously in a supervised
  Task), and immediately returns `{user_ts}` as JSON. All subsequent
  output (progress rows, streaming-buffer tokens for the final answer,
  the assistant message itself) lands in DB tables and reaches the FE via
  polling (`GET /sessions/:id/poll`). See specs/architecture.md
  §Polling-based delivery.

  Strict path separation
  ----------------------
  This handler looks up `session.mode` FIRST and branches into either the
  Confidant handler or the Assistant handler. The two paths share no
  command type and no dispatcher; body fields that belong to one path are
  not even parsed by the other.

  Request body (JSON) — Confidant mode:
    sessionId   — required
    content     — required
    images      — optional, list of base64 strings (photos or video frames)
    imageNames  — optional, list of filenames for each image
    files       — optional, list of %{"name", "content"} maps (extracted text)
    hasVideo    — optional bool, true when images are video frames

  Request body (JSON) — Assistant mode:
    sessionId        — required
    content          — required (empty allowed when attachmentNames is non-empty)
    attachmentNames  — optional, list of filenames already uploaded to
                       <session>/workspace/ at attach time. Paths are
                       inlined into the persisted user message.
    files            — optional, list of %{"name", "content"} maps

  Response: `{"user_ts": <int>}` on success (HTTP 202 Accepted).
  """

  import Plug.Conn
  alias DmhAi.Repo
  alias DmhAi.Adapters.Http
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  # 50 MB — accommodates multiple base64-encoded images in a Confidant request.
  @max_body_bytes 52_428_800
  # Guard against excessively large attachment lists.
  @max_attachments 20
  # Safety net — uploads almost always finish before send. If the FE raced
  # us we poll briefly before giving up.
  @attachment_wait_timeout_ms 30_000
  @attachment_poll_ms 200

  def post_chat(conn, user) do
    {:ok, body, conn} = read_body(conn, length: @max_body_bytes)
    d = Jason.decode!(body || "{}")

    session_id = String.trim(d["sessionId"] || "")

    cond do
      session_id == "" ->
        json(conn, 400, %{error: "Missing sessionId"})

      true ->
        case lookup_session_mode(session_id, user.id) do
          :not_found ->
            json(conn, 403, %{error: "Forbidden"})

          {:ok, "assistant"} ->
            handle_assistant_chat(conn, user, d, session_id)

          {:ok, _confidant_or_default} ->
            handle_confidant_chat(conn, user, d, session_id)
        end
    end
  end

  # ─── Assistant path ───────────────────────────────────────────────────────

  defp handle_assistant_chat(conn, user, d, session_id) do
    content = String.trim(d["content"] || "")
    files   = parse_files(d["files"])

    # Layer W — @-mention + &-workflow picker sidecars. Resolved
    # ids from the FE; both blocks augment the LLM-bound content
    # only. The persisted user message stays at the user's literal
    # text — internal augmentation MUST NOT leak into chat history.
    mentions  = parse_mentions(d["mentions"])
    workflows = parse_workflows(d["workflows"])

    # FE-supplied idempotency key. Persisted alongside the message so a
    # lost POST response + FE retry (or a BE crash + FE poll-based
    # recovery) resolves to the same canonical row instead of creating
    # a duplicate. Optional — non-FE POSTs may omit it. See
    # architecture.md §Mid-chain user message injection.
    client_msg_id =
      case d["client_msg_id"] do
        s when is_binary(s) and byte_size(s) > 0 and byte_size(s) <= 128 -> s
        _ -> nil
      end

    attachment_names =
      d["attachmentNames"]
      |> parse_string_list()
      |> Enum.take(@max_attachments)
      |> Enum.map(&sanitize_filename/1)

    has_payload = content != "" or files != [] or attachment_names != []

    if not has_payload do
      json(conn, 400, %{error: "Missing content"})
    else
      # Safety net: attach-time uploads should already be on disk; wait a
      # bounded window if they're not.
      if attachment_names != [] do
        workspace = DmhAi.Constants.session_workspace_dir(user.email, session_id)
        case wait_for_attachments(workspace, attachment_names) do
          :ok -> :ok
          :timeout ->
            Logger.warning("[AgentChat] attachment wait timed out session=#{session_id}")
        end
      end

      # Build the persisted user message — user's literal text plus
      # attachment paths. NO sidecar augmentation here; the BE is the
      # sole writer of session-message state, and "internal mechanic
      # must not be visible to user" means the persisted content
      # matches what the user actually typed.
      stored_content =
        if attachment_names == [] do
          content
        else
          paths = Enum.map_join(attachment_names, "\n", fn name -> "📎 workspace/" <> name end)
          if content == "", do: paths, else: content <> "\n\n" <> paths
        end

      # Defensive `&<slug>` resolution against the workflows table.
      # The FE picker registers a sidecar entry on selection, but
      # users sometimes type / paste a slug from memory. Scan the
      # user's prose; for tokens NOT already in the picker sidecar,
      # look up the workflow and (a) augment the workflows list if
      # found, or (b) collect into `unresolved` so the model can
      # tell the user "no such workflow" instead of hallucinating
      # an adjacent intent.
      org_id_for_user = org_id_for(user)
      {workflows, unresolved_slugs} =
        resolve_inline_ampersand_refs(stored_content, workflows, org_id_for_user)

      # LLM-bound content: stored_content + per-turn sidecar blocks.
      # Never persisted; the augmentation evaporates after this chain
      # ends (same lifecycle as a tool result decaying out of future
      # turns, stricter implementation — it never lands in
      # `sessions.messages` at all).
      llm_content =
        stored_content
        |> prepend_workflow_refs_block(workflows)
        |> prepend_unresolved_workflow_refs_block(unresolved_slugs)
        |> prepend_mentions_block(mentions)

      # Slash-command intercept (`/index`, `/memo`). Runs BEFORE the
      # LLM dispatch. Two outcomes:
      #   * `{:handled, _}` — runtime took it. Persistence + ack done;
      #     no LLM dispatch. `user_ts` is echoed back so the FE
      #     patches its optimistic local copy.
      #   * `:not_a_command` — plain user message, continue.
      command_result =
        DmhAi.Commands.dispatch(stored_content, session_id, user.id, request_lang(d))

      case command_result do
        {:handled, user_ts} ->
          json(conn, 200, %{user_ts: user_ts, handled: true})

        :not_a_command ->
          message = %{role: "user", content: stored_content}
          message = if client_msg_id, do: Map.put(message, :client_msg_id, client_msg_id), else: message

          {tz, local_date} = client_tz(conn)
          case DmhAi.Agent.UserAgentMessages.append(session_id, user.id, message) do
            {:ok, user_ts} ->
              fire_and_forget(conn, user_ts, fn ->
                Http.dispatch_assistant(user.id, session_id, llm_content, self(),
                  attachment_names: attachment_names,
                  files:            files,
                  timezone:         tz,
                  local_date:       local_date
                )
              end)

            {:error, reason} ->
              json(conn, 500, %{error: "Failed to persist message: #{inspect(reason)}"})
          end
      end
    end
  end

  # ─── Confidant path ───────────────────────────────────────────────────────

  defp handle_confidant_chat(conn, user, d, session_id) do
    content     = String.trim(d["content"] || "")
    images      = parse_images(d["images"])
    image_names = parse_string_list(d["imageNames"])
    files       = parse_files(d["files"])
    has_video   = d["hasVideo"] == true

    has_payload = content != "" or images != [] or files != []

    if not has_payload do
      json(conn, 400, %{error: "Missing content"})
    else
      # Slash-command intercept. Two outcomes:
      #   * `{:handled, _}` — runtime took it.
      #   * `:not_a_command` — plain user message, continue.
      command_result =
        DmhAi.Commands.dispatch(content, session_id, user.id, request_lang(d))

      case command_result do
        {:handled, user_ts} ->
          json(conn, 200, %{user_ts: user_ts, handled: true})

        :not_a_command ->
          # BE owns every persisted message write. Store the user's
          # literal text (no augmentation); image base64 payloads
          # flow through the current request and feed the LLM
          # inline, but are not persisted on the stored message.
          {tz, local_date} = client_tz(conn)
          case DmhAi.Agent.UserAgentMessages.append(session_id, user.id,
                  %{role: "user", content: content}) do
            {:ok, user_ts} ->
              fire_and_forget(conn, user_ts, fn ->
                Http.dispatch_confidant(user.id, session_id, content, self(),
                  images:      images,
                  image_names: image_names,
                  files:       files,
                  has_video:   has_video,
                  timezone:    tz,
                  local_date:  local_date
                )
              end)

            {:error, reason} ->
              json(conn, 500, %{error: "Failed to persist message: #{inspect(reason)}"})
          end
      end
    end
  end

  # Dispatch the turn and return immediately. The pipeline runs in a
  # Task.Supervisor-supervised process; its output flows to DB tables
  # (session.messages, session_progress, sessions.stream_buffer) and the
  # FE polls `/sessions/:id/poll` for updates. No chunked response here.
  #
  # For Assistant mode, busy is NOT an error: the user message has
  # already been persisted to `session.messages` before we get here,
  # so it's queued by definition. The UserAgent's chain-complete hook
  # (and the mid-chain splice inside `session_chain_loop`) picks it up.
  # See architecture.md §Mid-chain user message injection.
  #
  # For Confidant mode, there is no chain to fold into — the pipeline is
  # a one-shot streaming reply. Busy stays a 409 so the FE surfaces
  # "please wait" to the user (matches pre-Phase-2 behaviour for
  # Confidant specifically).
  defp fire_and_forget(conn, user_ts, dispatch_fun) do
    case dispatch_fun.() do
      :ok ->
        json(conn, 202, %{user_ts: user_ts})

      {:error, :queued} ->
        json(conn, 202, %{user_ts: user_ts, queued: true})

      {:error, :busy} ->
        json(conn, 409, %{error: "Agent is busy, please wait", user_ts: user_ts})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason), user_ts: user_ts})
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp lookup_session_mode(session_id, user_id) do
    result = query!(Repo, "SELECT mode FROM sessions WHERE id=? AND user_id=?", [session_id, user_id])

    case result.rows do
      [[mode]] -> {:ok, mode || "confidant"}
      _        -> :not_found
    end
  end

  defp wait_for_attachments(workspace, names) do
    deadline = System.os_time(:millisecond) + @attachment_wait_timeout_ms
    do_wait_attachments(workspace, names, deadline)
  end

  defp do_wait_attachments(workspace, names, deadline) do
    missing = Enum.reject(names, &File.exists?(Path.join(workspace, &1)))

    cond do
      missing == [] ->
        :ok

      System.os_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(@attachment_poll_ms)
        do_wait_attachments(workspace, names, deadline)
    end
  end

  # Match the server-side sanitization in post_session_attachment so names align.
  defp sanitize_filename(name) when is_binary(name),
    do: Regex.replace(~r/[^\w.\-]/, name, "_")

  defp parse_images(nil), do: []
  defp parse_images(list) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 != ""))
  end
  defp parse_images(_), do: []

  defp parse_string_list(nil), do: []
  defp parse_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp parse_string_list(_), do: []

  # Layer W — @-mention sidecar. FE ships an array of
  # `{token, user_id}` pairs; we keep only entries with a non-empty
  # binary user_id (the LLM sees them as authoritative).
  defp parse_mentions(nil), do: []

  defp parse_mentions(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"token" => t, "user_id" => uid}
        when is_binary(t) and is_binary(uid) and t != "" and uid != "" ->
        [%{token: t, user_id: uid}]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.token)
    |> Enum.take(20)
  end

  defp parse_mentions(_), do: []

  defp prepend_mentions_block(content, []), do: content

  defp prepend_mentions_block(content, mentions) when is_list(mentions) do
    lines =
      mentions
      |> Enum.map(fn %{token: t, user_id: uid} -> "  " <> t <> " => " <> uid end)
      |> Enum.join("\n")

    "<mentions>\n" <> lines <> "\n</mentions>\n" <> content
  end

  # Layer W — &-workflow sidecar. FE ships an array of resolved
  # workflow references from the picker. The BE prepends a
  # `<workflow_references>` block to the LLM-bound content so the
  # model has authoritative slug + metadata + trigger schema for
  # every `&<slug>` it sees in the user's text. Never persisted —
  # augmentation evaporates after this chain ends.
  defp parse_workflows(nil), do: []

  defp parse_workflows(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"token" => t, "id" => id} = e
        when is_binary(t) and is_binary(id) and t != "" and id != "" ->
        [%{
           token:           t,
           id:              id,
           display_name:    safe_string(e["display_name"]),
           description:     safe_string(e["description"]),
           current_version: safe_int(e["current_version"]),
           trigger_kind:    safe_trigger_kind(e["trigger_kind"]),
           trigger_inputs:  safe_list(e["trigger_inputs"])
         }]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.token)
    |> Enum.take(10)
  end

  defp parse_workflows(_), do: []

  defp prepend_workflow_refs_block(content, []), do: content

  defp prepend_workflow_refs_block(content, refs) when is_list(refs) do
    body =
      refs
      |> Enum.map(&render_workflow_ref/1)
      |> Enum.join("\n\n")

    "<workflow_references>\n" <> body <> "\n</workflow_references>\n" <> content
  end

  # Surfaces `&<slug>` tokens the user typed that don't match any
  # workflow. The model is taught (in `<workflow_authoring>`) to tell
  # the user the slug is unknown instead of guessing an adjacent
  # intent. Empty list → no block emitted.
  defp prepend_unresolved_workflow_refs_block(content, []), do: content

  defp prepend_unresolved_workflow_refs_block(content, slugs) when is_list(slugs) do
    body = slugs |> Enum.map(fn s -> "  &" <> s end) |> Enum.join("\n")

    "<unresolved_workflow_references>\n" <> body <>
      "\n</unresolved_workflow_references>\n" <> content
  end

  # Scan user content for `&<slug>` tokens, resolve against the
  # workflows table. Returns `{augmented_workflows_list, unresolved_slugs}`.
  # Tokens already present in the picker-sourced sidecar are skipped;
  # tokens not in DB are collected as unresolved.
  defp resolve_inline_ampersand_refs(content, sidecar_workflows, org_id) when is_binary(content) do
    already_resolved =
      sidecar_workflows
      |> Enum.map(fn w -> w.id end)
      |> MapSet.new()

    inline_slugs =
      Regex.scan(~r/(?:^|\s)&([a-z0-9_]+)\b/, content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(already_resolved, &1))

    {newly_resolved, unresolved} =
      Enum.reduce(inline_slugs, {[], []}, fn slug, {res_acc, unres_acc} ->
        case DmhAi.Workflows.get_workflow(org_id, slug) do
          nil ->
            {res_acc, [slug | unres_acc]}

          wf ->
            entry = inline_workflow_entry(org_id, wf)
            {[entry | res_acc], unres_acc}
        end
      end)

    {sidecar_workflows ++ Enum.reverse(newly_resolved), Enum.reverse(unresolved)}
  end

  defp resolve_inline_ampersand_refs(_, sidecar_workflows, _org_id),
    do: {sidecar_workflows, []}

  defp inline_workflow_entry(org_id, wf) do
    ver = DmhAi.Workflows.get_version(org_id, wf.id, wf.current_version)

    {kind, inputs} =
      case ver do
        %{ir: ir} ->
          ir
          |> Map.get("nodes", [])
          |> Enum.find(fn n -> n["kind"] == "trigger" end)
          |> case do
            nil -> {"manual", []}
            t   -> {Map.get(t, "trigger_kind", "manual"), Map.get(t, "inputs", [])}
          end

        _ ->
          {"manual", []}
      end

    %{
      token:           "&" <> wf.id,
      id:              wf.id,
      display_name:    wf.display_name,
      description:     Map.get(wf, :description, ""),
      current_version: wf.current_version,
      trigger_kind:    kind,
      trigger_inputs:  inputs
    }
  end

  # Resolve the user's org_id. Falls back to the install's default
  # when the user record carries nothing usable.
  defp org_id_for(user) do
    case Map.get(user, :org_id) do
      s when is_binary(s) and s != "" -> s
      _ -> DmhAi.Constants.default_org_id()
    end
  end

  defp render_workflow_ref(%{token: t, id: id, display_name: dn, description: desc,
                             current_version: ver, trigger_kind: kind,
                             trigger_inputs: inputs}) do
    schema =
      case Jason.encode(inputs || []) do
        {:ok, j} -> j
        _        -> "[]"
      end

    "  " <> t <> "\n" <>
      "    id: " <> id <> "\n" <>
      "    display_name: " <> (dn || "") <> "\n" <>
      "    description: " <> (desc || "") <> "\n" <>
      "    current_version: " <> to_string(ver || 0) <> "\n" <>
      "    trigger_kind: " <> kind <> "\n" <>
      "    trigger_inputs: " <> schema
  end

  defp safe_string(v) when is_binary(v), do: v
  defp safe_string(_),                   do: ""

  defp safe_int(v) when is_integer(v), do: v
  defp safe_int(_),                    do: 0

  defp safe_list(v) when is_list(v), do: v
  defp safe_list(_),                 do: []

  defp safe_trigger_kind(v) when v in ["manual", "poll", "schedule", "webhook"], do: v
  defp safe_trigger_kind(_),                                                     do: "manual"

  defp parse_files(nil), do: []
  defp parse_files(list) when is_list(list) do
    Enum.filter(list, fn f ->
      is_map(f) and is_binary(f["name"]) and is_binary(f["content"])
    end)
  end
  defp parse_files(_), do: []

  # Read the FE-supplied locale (`I18n._lang`) from the request body.
  # Used by the slash-command runtime (e.g. /memo's static-i18n ack)
  # to render in the user's language without an LLM round-trip. Falls
  # back to "en" if absent or malformed; downstream `normalize_lang/1`
  # in `Commands.Memo` validates against the supported set.
  defp request_lang(%{"lang" => l}) when is_binary(l) and l != "", do: l
  defp request_lang(_), do: "en"

  # Read the client's timezone + locally-computed date from the
  # `X-Timezone` and `X-Local-Date` request headers. Both come from
  # `apiFetch` in `core.js`, which fills them with
  # `Intl.DateTimeFormat().resolvedOptions().timeZone` and a Sweden-
  # locale `toLocaleDateString` (always YYYY-MM-DD). Returns
  # `{tz, local_date}` with `nil` for any header the FE didn't send.
  # The system prompt builder treats nils as "fall back to UTC."
  #
  # IANA name length is bounded (longest known is ~30 chars,
  # "America/Argentina/Buenos_Aires"); we cap at 64 to avoid log
  # noise on garbage headers. Date is shape-validated as
  # YYYY-MM-DD; anything else → nil.
  defp client_tz(conn) do
    tz =
      case get_req_header(conn, "x-timezone") do
        [s | _] when is_binary(s) and byte_size(s) > 0 and byte_size(s) <= 64 -> s
        _ -> nil
      end

    local_date =
      case get_req_header(conn, "x-local-date") do
        [s | _] ->
          if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, s), do: s, else: nil
        _ ->
          nil
      end

    {tz, local_date}
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
