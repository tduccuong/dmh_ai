# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.FormSubmission do
  @moduledoc """
  POST /sessions/:session_id/inputs/:token — submission endpoint for
  `request_input` forms.

  Validates the token resolves to a pending form on this session,
  enforces single-use, expiry and field-shape, then either:

  * Marks the assistant form submitted, appends a synth `user`
    message carrying the values, and auto-resumes the chain
    (`request_input` form), or
  * Spawns the slow MCP handshake in a Task and appends a
    `service_connected` / `service_setup_authorize` message when the
    handshake returns (`connect_mcp_setup` form).
  """

  import Plug.Conn, only: [read_body: 1]

  alias DmhAi.Repo
  alias DmhAi.Handlers.Data
  alias DmhAi.Handlers.Data.Sessions
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Map dropdown option values (set in `connect_mcp`'s api_key
  # form) to the actual header name + optional value prefix. Keeping
  # this small table in one place lets the form options stay
  # human-friendly while the BE knows exactly what bytes to send.
  @auth_header_choices %{
    "Authorization"      => {"Authorization",      "Bearer "},
    "x-api-key"          => {"x-api-key",          ""},
    "x-consumer-api-key" => {"x-consumer-api-key", ""}
  }

  # POST /sessions/:session_id/inputs/:token
  # Submission endpoint for `request_input` forms. Body: {"values":
  # {field_name: value, ...}}. Validates the token resolves to a
  # pending form on this session, enforces single-use, expiry, and
  # field-shape, then:
  #   1. Marks the assistant message's `form` as submitted (stores
  #      `values_meta` only — no plaintext on the assistant message).
  #   2. Appends a synthetic user-role message carrying the structured
  #      payload, which the model sees on the next chain.
  #   3. Auto-resumes the session's chain via the same plumbing as a
  #      regular mid-chain user message.
  def submit_input(conn, user, session_id, token) do
    case parse_input_submission(conn) do
      {:error, status, msg} ->
        Data.json(conn, status, %{error: msg})

      {:ok, values} ->
        cond do
          not Sessions.owns_session?(session_id, user.id) ->
            Data.json(conn, 403, %{error: "Forbidden"})

          true ->
            case do_submit_input(session_id, user.id, token, values) do
              {:ok, :sync, _ts} ->
                # request_input form_response — the synth user message
                # is already in session.messages; auto-resume the chain
                # immediately so the model sees the values.
                _ = trigger_auto_resume(user.id, session_id)
                Data.json(conn, 200, %{ok: true})

              {:ok, :async, _ts} ->
                # connect_mcp_setup — the spawned Task owns the
                # service_connected message append and auto-resume
                # dispatch (after the MCP handshake completes). No
                # auto-resume from here.
                Data.json(conn, 200, %{ok: true})

              {:error, :not_found} ->
                Data.json(conn, 404, %{error: "No pending form for that token"})

              {:error, :already_submitted} ->
                Data.json(conn, 409, %{error: "Form already submitted"})

              {:error, :expired} ->
                Data.json(conn, 410, %{error: "Form expired"})

              {:error, :schema_mismatch} ->
                Data.json(conn, 400, %{error: "Submitted values don't match form schema"})
            end
        end
    end
  end

  defp parse_input_submission(conn) do
    case read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, %{"values" => values}} when is_map(values) -> {:ok, values}
          _ -> {:error, 400, "Body must be JSON {\"values\": {...}}"}
        end

      _ ->
        {:error, 400, "Empty body"}
    end
  end

  defp do_submit_input(session_id, user_id, token, values) do
    result =
      query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
             [session_id, user_id])

    case result.rows do
      [[msgs_json]] ->
        msgs = Jason.decode!(msgs_json || "[]")
        now = System.os_time(:millisecond)

        case find_form(msgs, token) do
          nil ->
            {:error, :not_found}

          {idx, msg, form} ->
            cond do
              form["submitted"] == true ->
                {:error, :already_submitted}

              is_integer(form["expires_at"]) and form["expires_at"] < now ->
                {:error, :expired}

              not values_match_schema?(form["fields"] || [], values) ->
                {:error, :schema_mismatch}

              true ->
                meta = build_values_meta(form["fields"] || [], values)
                updated_form =
                  form
                  |> Map.put("submitted", true)
                  |> Map.put("submitted_at", now)
                  |> Map.put("values_meta", meta)

                updated_msg = Map.put(msg, "form", updated_form)

                case form["kind"] do
                  "connect_mcp_setup" ->
                    # Persist the form-submitted state synchronously so
                    # the FE optimistic re-render matches what the next
                    # poll returns. Then hand the slow work (MCP
                    # handshake + tools/list) off to a Task so the POST
                    # returns immediately. Append a pending progress
                    # row so polling sees `is_working=true` and the
                    # status bar shows activity during the handshake.
                    new_msgs = List.replace_at(msgs, idx, updated_msg)

                    query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
                           [Jason.encode!(new_msgs), session_id, user_id])

                    spawn_connect_mcp_setup(session_id, user_id, form, values)
                    {:ok, :async, now}

                  _ ->
                    synth_msg = build_form_response_msg(form, values, token, now)

                    new_msgs =
                      msgs
                      |> List.replace_at(idx, updated_msg)
                      |> Kernel.++([synth_msg])

                    query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
                           [Jason.encode!(new_msgs), session_id, user_id])

                    {:ok, :sync, now}
                end
            end
        end

      _ ->
        {:error, :not_found}
    end
  end

  # `request_input` form — synth a user-role message carrying the
  # submitted values so the model sees them on the next chain. LLM
  # chat-completion APIs forward only `role` + `content`; custom
  # fields drop silently on serialisation, so the values must live
  # in `content`.
  defp build_form_response_msg(form, values, token, now) do
    content =
      "[input submitted via request_input form]\n" <>
        Enum.map_join(form["fields"] || [], "\n", fn f ->
          name = f["name"] || f[:name]
          "#{name}: #{Map.get(values, name, "")}"
        end)

    %{
      "role"          => "user",
      "content"       => content,
      "ts"            => now,
      "kind"          => "form_response",
      "form_response" => %{"token" => token, "values" => values}
    }
  end

  # `connect_mcp_setup` form. Heavy work (MCP handshake +
  # tools/list, ~3 s) runs in a fire-and-forget Task so the POST
  # returns fast. A pending session_progress row appears in the chat
  # immediately so the FE polling shows "Assistant is …" status
  # during the handshake; the Task flips it to done and appends the
  # `service_connected` synthetic user message + auto-resumes when
  # the work finishes.
  defp spawn_connect_mcp_setup(session_id, user_id, form, values) do
    setup = form["setup_payload"] || %{}
    alias_ = setup["alias"] || "service"

    {:ok, prog_row} =
      DmhAi.Agent.SessionProgress.append_tool_pending(
        %{session_id: session_id, user_id: user_id},
        "Connecting #{alias_}…"
      )

    Task.Supervisor.start_child(DmhAi.Agent.TaskSupervisor, fn ->
      do_connect_mcp_setup(session_id, user_id, form, values, prog_row.id)
    end)

    :ok
  end

  defp do_connect_mcp_setup(session_id, user_id, form, values, prog_id) do
    setup = form["setup_payload"] || %{}

    # The only setup form `connect_mcp` emits today is the api_key
    # form (single-field paste-your-key + auth-header dropdown). The
    # BYO-OAuth setup form is gone — admin catalog curation is the
    # path for in-house servers needing manual OAuth endpoints.
    result =
      case setup["auth_method"] do
        "api_key" -> finalize_api_key_setup(setup, values, user_id)
        other     -> {:error, "auth_method '#{inspect(other)}' not supported"}
      end

    DmhAi.Agent.SessionProgress.mark_tool_done(prog_id)

    msg = build_service_connected_msg(setup, result)
    append_session_user_msg(session_id, user_id, msg)

    trigger_auto_resume(user_id, session_id)
    :ok
  rescue
    e ->
      DmhAi.Agent.SessionProgress.mark_tool_done(prog_id)

      msg = build_service_connected_msg(form["setup_payload"] || %{},
              {:error, "internal error: #{inspect(e)}"})
      append_session_user_msg(session_id, user_id, msg)

      trigger_auto_resume(user_id, session_id)
      :ok
  end

  defp finalize_api_key_setup(setup, values, user_id) do
    alias_     = setup["alias"]
    server_url = setup["server_url"]
    session_id = setup["session_id"]
    canonical  = server_url
    api_key    = (values["api_key"] || "") |> String.trim()
    choice     = (values["auth_header"] || "Authorization") |> String.trim()

    cond do
      api_key == "" ->
        {:error, "API key is empty"}

      not Map.has_key?(@auth_header_choices, choice) ->
        {:error, "Unknown auth header choice: #{inspect(choice)}"}

      not is_binary(session_id) ->
        {:error, "setup payload missing session_id"}

      true ->
        {header, prefix} = Map.fetch!(@auth_header_choices, choice)
        value = prefix <> api_key

        handshake_ctx = %{
          server_url:         server_url,
          canonical_resource: canonical,
          auth: %{
            type:               "api_key",
            header:             header,
            key:                value,
            canonical_resource: canonical
          }
        }

        with {:ok, _info, sid} <- DmhAi.MCP.Client.initialize(handshake_ctx),
             {:ok, tools}       <- DmhAi.MCP.Client.list_tools(handshake_ctx, sid) do
          cred_payload = %{
            "api_key"            => value,
            "api_key_header"     => header,
            "server_url"         => server_url,
            "alias"              => alias_,
            "canonical_resource" => canonical
          }

          DmhAi.Auth.Credentials.save(
            user_id,
            "mcp:" <> canonical,
            "api_key_mcp",
            cred_payload,
            account: "",
            notes:   "API-key MCP connection: #{alias_} (header: #{header})"
          )

          DmhAi.MCP.Registry.authorize(user_id, alias_, canonical, server_url, nil)
          DmhAi.MCP.Registry.set_authorized_tools(user_id, alias_, tools)
          DmhAi.MCP.Registry.attach(session_id, user_id, alias_)
          {:ok, %{alias: alias_, tools_count: length(tools)}}
        else
          {:error, reason} ->
            {:error, format_handshake_error(choice, reason)}
        end
    end
  end

  defp format_handshake_error(choice, {:status, 401, body}) do
    server_msg =
      case body do
        %{"error" => msg} when is_binary(msg) -> msg
        _ -> inspect(body)
      end

    other_choices =
      @auth_header_choices
      |> Map.keys()
      |> Enum.reject(&(&1 == choice))
      |> Enum.join(" / ")

    "Server returned 401 with the `#{choice}` auth header. Server says: #{server_msg}. " <>
      "If the URL is right, retry connect_mcp and pick a different header (#{other_choices}). " <>
      "If that still 401s, the URL is probably not a real MCP endpoint."
  end

  defp format_handshake_error(choice, {:status, status, body}),
    do: "Server returned HTTP #{status} with the `#{choice}` header. Body: #{inspect(body)}."

  defp format_handshake_error(choice, reason),
    do: "MCP handshake failed (header: `#{choice}`): #{inspect(reason)}. The URL may not be a real MCP endpoint."

  # ── oauth (manual) form finalization ──────────────────────────────────
  #
  # The form was filled with the AS endpoints + client credentials the
  # user copied from the provider's dashboard (used when the AS does
  # NOT publish RFC 8414 metadata or RFC 7591 DCR). We synthesise the
  # ASM map the rest of the pipeline expects, save the manual
  # `oauth_client` row keyed by auth_endpoint (so the callback can
  # fold client identifiers into the token payload), and feed
  # everything through the same `Auth.OAuth2.init_flow/1` the auto
  # path uses. Returns `{:ok, %{alias, auth_url}}` on success — the
  # caller renders the auth_url to the user; the OAuth callback at
  # `/oauth/callback` finishes the token exchange + handshake.

  defp build_service_connected_msg(_setup, {:ok, %{alias: alias_, tools_count: n}}) do
    %{
      "role"              => "user",
      "content"           => "[#{alias_} connected — #{n} tools available]",
      "ts"                => System.os_time(:millisecond),
      "kind"              => "service_connected",
      "service_connected" => %{"alias" => alias_, "tools_count" => n, "error" => nil}
    }
  end

  # Manual OAuth path: form was submitted, init_flow succeeded, and we
  # now have an authorization URL the user must visit to grant access.
  # The connection completes asynchronously when the OAuth callback
  # fires — `finalize_connection` runs the MCP handshake there and
  # auto-resumes the assistant. The message here renders the auth_url
  # inline as a clickable markdown link so the user can act without
  # an extra assistant turn relaying it.
  defp build_service_connected_msg(_setup, {:ok, %{alias: alias_, auth_url: auth_url}}) do
    %{
      "role"              => "user",
      "content"           =>
        "[#{alias_} authorization step — please visit this URL to authorize, then your task will resume:\n\n" <>
          auth_url <>
          "\n]",
      "ts"                => System.os_time(:millisecond),
      "kind"              => "service_setup_authorize",
      "service_setup_authorize" => %{"alias" => alias_, "auth_url" => auth_url}
    }
  end

  defp build_service_connected_msg(setup, {:error, reason}) do
    alias_ = setup["alias"] || "service"

    %{
      "role"              => "user",
      "content"           => "[#{alias_} connection error — #{reason}]",
      "ts"                => System.os_time(:millisecond),
      "kind"              => "service_connected",
      "service_connected" => %{"alias" => alias_, "tools_count" => 0, "error" => reason}
    }
  end

  defp append_session_user_msg(session_id, user_id, msg) do
    case query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [session_id, user_id]) do
      %{rows: [[msgs_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")
        new_msgs = msgs ++ [msg]

        query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
               [Jason.encode!(new_msgs), session_id, user_id])
        :ok

      _ ->
        :ok
    end
  end

  defp trigger_auto_resume(user_id, session_id) do
    case DmhAi.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} -> send(pid, {:auto_resume_assistant, session_id})
      _          -> :ok
    end
  end

  defp find_form(msgs, token) do
    msgs
    |> Enum.with_index()
    |> Enum.find_value(fn {m, idx} ->
      with %{"role" => "assistant", "form" => %{"token" => ^token} = form} <- m do
        {idx, m, form}
      else
        _ -> nil
      end
    end)
  end

  defp values_match_schema?(fields, values) when is_list(fields) and is_map(values) do
    Enum.all?(fields, fn f ->
      name = f["name"] || f[:name]
      Map.has_key?(values, name) and is_binary(values[name])
    end)
  end

  defp values_match_schema?(_, _), do: false

  # Build a per-field [{name, secret, length}] list to persist on the
  # assistant message — gives the FE enough to render a "✓ Submitted"
  # summary without ever holding the plaintext value after submit.
  defp build_values_meta(fields, values) do
    Enum.map(fields, fn f ->
      name   = f["name"]   || f[:name]
      secret = f["secret"] || f[:secret] || false
      val    = Map.get(values, name) || ""
      %{"name" => name, "secret" => secret, "length" => String.length(val)}
    end)
  end
end
