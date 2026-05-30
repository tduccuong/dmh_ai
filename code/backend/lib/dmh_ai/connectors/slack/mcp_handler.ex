# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Slack.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Slack connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a Slack
  Web API method at `https://slack.com/api/*`:

    message.send       — POST /chat.postMessage
    message.update     — POST /chat.update
    message.schedule   — POST /chat.scheduleMessage
    message.delete     — POST /chat.delete
    message.find       — GET  /search.messages
    channel.find       — GET  /conversations.list
    channel.history    — GET  /conversations.history
    channel.create     — POST /conversations.create
    channel.invite     — POST /conversations.invite
    channel.archive    — POST /conversations.archive
    user.find_by_email — GET  /users.lookupByEmail
    user.list          — GET  /users.list
    user.set_status    — POST /users.profile.set
    file.upload        — POST /files.upload  (multipart/form-data)
    pin.add            — POST /pins.add
    reaction.add       — POST /reactions.add

  Fixed host (`https://slack.com/api`), no per-instance templating.
  Standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## HTTP 200 on failure

  The Slack Web API returns **HTTP 200 even on failure**, with a body
  `%{"ok" => false, "error" => "<code>"}`. So a 2xx status alone does
  NOT mean success — every `response` parser inspects the `"ok"` field:

    * `%{"ok" => true} = body` → `{:ok, <mapped>}`
    * `%{"ok" => false} = body` → `{:error, body}` — the dispatcher
      then runs the connector's `remap_error/1`, which matches the
      `%{"ok" => false, "error" => ...}` shape and maps the vendor
      code to the canonical class.

  Returning the raw error body (not a pre-classified atom) keeps all
  vendor → canonical mapping in one place (`Slack.remap_error/1`).

  ## `file.upload` — deprecated endpoint

  Slack has moved file ingestion to a 2-step flow
  (`files.getUploadURLExternal` + `files.completeUploadExternal`). The
  legacy `POST /files.upload` (multipart/form-data) is still live and
  remains the simpler call for the small-text-attachment surface this
  connector exposes. When Slack switches it off, swap in the 2-step
  flow inside the custom `file_upload/2` handler — the typed args /
  return shape do not change.
  """

  alias DmhAi.Connectors.MCPServer.{FunctionSpec, RestBridge}
  require Logger

  @api_base "https://slack.com/api"

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "slack", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "message.send" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/chat.postMessage",
        request: &message_send_request/2,
        response: &message_send_response/2,
        doc:     "Post a message to a channel or thread."
      },
      "message.update" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/chat.update",
        request: &message_update_request/2,
        response: &message_update_response/2,
        doc:     "Edit an existing message."
      },
      "channel.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/conversations.list",
        request: &channel_find_request/2,
        response: &channel_find_response/2,
        doc:     "List channels; optional name filter applied client-side."
      },
      "channel.history" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/conversations.history",
        request: &channel_history_request/2,
        response: &channel_history_response/2,
        doc:     "Read recent messages in a channel."
      },
      "message.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/search.messages",
        request: &message_find_request/2,
        response: &message_find_response/2,
        doc:     "Full-text search across messages."
      },
      "user.find_by_email" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/users.lookupByEmail",
        request: &user_find_by_email_request/2,
        response: &user_find_by_email_response/2,
        doc:     "Look a user up by email address."
      },
      "user.list" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/users.list",
        request: &user_list_request/2,
        response: &user_list_response/2,
        doc:     "List workspace users."
      },
      "reaction.add" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/reactions.add",
        request: &reaction_add_request/2,
        response: &reaction_add_response/2,
        doc:     "Add an emoji reaction to a message."
      },
      "channel.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/conversations.create",
        request: &channel_create_request/2,
        response: &channel_create_response/2,
        doc:     "Create a public or private channel."
      },
      "channel.invite" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/conversations.invite",
        request: &channel_invite_request/2,
        response: &channel_invite_response/2,
        doc:     "Invite one or more users to a channel."
      },
      "channel.archive" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/conversations.archive",
        request: &channel_archive_request/2,
        response: &channel_archive_response/2,
        doc:     "Archive a channel."
      },
      "message.schedule" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/chat.scheduleMessage",
        request: &message_schedule_request/2,
        response: &message_schedule_response/2,
        doc:     "Schedule a message for future delivery."
      },
      "message.delete" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/chat.delete",
        request: &message_delete_request/2,
        response: &message_delete_response/2,
        doc:     "Delete a previously posted message."
      },
      "file.upload" => %FunctionSpec{
        handler: &file_upload/2,
        doc:     "Upload a text file to a channel (multipart/form-data)."
      },
      "pin.add" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/pins.add",
        request: &pin_add_request/2,
        response: &pin_add_response/2,
        doc:     "Pin a message in a channel."
      },
      "user.set_status" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/users.profile.set",
        request: &user_set_status_request/2,
        response: &user_set_status_response/2,
        doc:     "Set the connecting user's status text / emoji."
      }
    }
  end

  # ─── message.send — POST /chat.postMessage ────────────────────────────

  defp message_send_request(args, _ctx) do
    body =
      %{"channel" => args["channel"], "text" => args["text"]}
      |> maybe_put_kv("thread_ts", Map.get(args, "thread_ts"))

    [json: body]
  end

  defp message_send_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      %{"ts" => to_string(b["ts"]), "channel" => to_string(b["channel"])}
    end)
  end

  # ─── message.update — POST /chat.update ───────────────────────────────

  defp message_update_request(args, _ctx) do
    [json: %{"channel" => args["channel"], "ts" => args["ts"], "text" => args["text"]}]
  end

  defp message_update_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b -> %{"ts" => to_string(b["ts"])} end)
  end

  # ─── channel.find — GET /conversations.list ───────────────────────────

  defp channel_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  # Slack's `conversations.list` has no server-side name filter; the
  # optional `query` arg is a request hint only (it can't be applied in
  # the response parser, which receives no args). The full channel list
  # is returned normalised to `{id, name}`.
  defp channel_find_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      channels =
        b
        |> Map.get("channels", [])
        |> Enum.map(&normalise_channel/1)

      %{"channels" => channels}
    end)
  end

  defp normalise_channel(c) do
    %{
      "id"   => to_string(c["id"]),
      "name" => c["name"]
    }
  end

  # ─── channel.history — GET /conversations.history ─────────────────────

  defp channel_history_request(args, _ctx) do
    params =
      %{"channel" => args["channel"]}
      |> maybe_put_kv("limit", Map.get(args, "limit"))

    [params: params]
  end

  defp channel_history_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      %{"messages" => Map.get(b, "messages", [])}
    end)
  end

  # ─── message.find — GET /search.messages ──────────────────────────────

  defp message_find_request(args, _ctx) do
    params =
      %{"query" => args["query"]}
      |> maybe_put_kv("count", Map.get(args, "limit"))

    [params: params]
  end

  # `search.messages` nests its matches under `messages.matches`.
  defp message_find_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      matches = get_in(b, ["messages", "matches"]) || []
      %{"messages" => matches}
    end)
  end

  # ─── user.find_by_email — GET /users.lookupByEmail ────────────────────

  defp user_find_by_email_request(args, _ctx) do
    [params: %{"email" => args["email"]}]
  end

  defp user_find_by_email_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b -> %{"user" => Map.get(b, "user", %{})} end)
  end

  # ─── user.list — GET /users.list ──────────────────────────────────────

  defp user_list_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp user_list_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b -> %{"users" => Map.get(b, "members", [])} end)
  end

  # ─── reaction.add — POST /reactions.add ───────────────────────────────

  defp reaction_add_request(args, _ctx) do
    [json: %{
       "channel"   => args["channel"],
       "timestamp" => args["timestamp"],
       "name"      => args["name"]
     }]
  end

  defp reaction_add_response(s, body) when s in 200..299 do
    ok_or_error(body, fn _b -> %{"ok" => true} end)
  end

  # ─── channel.create — POST /conversations.create ──────────────────────

  defp channel_create_request(args, _ctx) do
    body =
      %{"name" => args["name"]}
      |> maybe_put_kv("is_private", Map.get(args, "is_private"))

    [json: body]
  end

  defp channel_create_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      %{"channel_id" => to_string(get_in(b, ["channel", "id"]) || "")}
    end)
  end

  # ─── channel.invite — POST /conversations.invite ──────────────────────

  # Slack's `conversations.invite` takes `users` as a comma-joined
  # string of user ids, not a JSON array. Join the typed-list arg.
  defp channel_invite_request(args, _ctx) do
    users_csv =
      args
      |> Map.get("user_ids", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.join(",")

    [json: %{"channel" => args["channel_id"], "users" => users_csv}]
  end

  defp channel_invite_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      %{"channel_id" => to_string(get_in(b, ["channel", "id"]) || "")}
    end)
  end

  # ─── channel.archive — POST /conversations.archive ────────────────────

  defp channel_archive_request(args, _ctx) do
    [json: %{"channel" => args["channel_id"]}]
  end

  defp channel_archive_response(s, body) when s in 200..299 do
    ok_or_error(body, fn _b -> %{"ok" => true} end)
  end

  # ─── message.schedule — POST /chat.scheduleMessage ────────────────────

  defp message_schedule_request(args, _ctx) do
    [json: %{
       "channel" => args["channel_id"],
       "text"    => args["text"],
       "post_at" => args["post_at_epoch"]
     }]
  end

  defp message_schedule_response(s, body) when s in 200..299 do
    ok_or_error(body, fn b ->
      %{
        "scheduled_message_id" => to_string(b["scheduled_message_id"] || ""),
        "post_at"              => b["post_at"]
      }
    end)
  end

  # ─── message.delete — POST /chat.delete ───────────────────────────────

  defp message_delete_request(args, _ctx) do
    [json: %{"channel" => args["channel_id"], "ts" => args["ts"]}]
  end

  defp message_delete_response(s, body) when s in 200..299 do
    ok_or_error(body, fn _b -> %{"ok" => true} end)
  end

  # ─── file.upload — POST /files.upload (multipart/form-data) ───────────

  # Custom handler — multipart/form-data does not fit the default JSON
  # `request` shape, so the function owns the full HTTP call via
  # `RestBridge.raw_request/2`. The 200-on-failure invariant still
  # holds: branch on `"ok"` and surface the raw error body so
  # `remap_error/1` owns classification.
  defp file_upload(args, ctx) do
    boundary = "----dmh-ai-slack-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    fields =
      [
        {"channels", args["channel_id"]},
        {"filename", args["filename"]},
        {"content",  args["content"]}
      ]
      |> maybe_append_field("title", Map.get(args, "title"))

    body = build_multipart_body(boundary, fields)

    headers = [
      {"content-type", "multipart/form-data; boundary=#{boundary}"},
      {"authorization", "Bearer #{ctx[:bearer_token] || ""}"}
    ]

    opts = [url: "#{@api_base}/files.upload", headers: headers, body: body]

    case RestBridge.raw_request(:post, opts) do
      {:ok, status, resp_body} when status in 200..299 ->
        ok_or_error(resp_body, fn b ->
          %{"file_id" => to_string(get_in(b, ["file", "id"]) || "")}
        end)

      {:ok, _status, resp_body} ->
        {:error, resp_body}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_append_field(fields, _k, nil), do: fields
  defp maybe_append_field(fields, _k, ""),  do: fields
  defp maybe_append_field(fields, k, v),    do: fields ++ [{k, v}]

  defp build_multipart_body(boundary, fields) do
    parts =
      Enum.flat_map(fields, fn {name, value} ->
        [
          "--", boundary, "\r\n",
          ~s(content-disposition: form-data; name="), name, ~s("), "\r\n\r\n",
          to_string(value), "\r\n"
        ]
      end)

    IO.iodata_to_binary(parts ++ ["--", boundary, "--", "\r\n"])
  end

  # ─── pin.add — POST /pins.add ─────────────────────────────────────────

  defp pin_add_request(args, _ctx) do
    [json: %{"channel" => args["channel_id"], "timestamp" => args["ts"]}]
  end

  defp pin_add_response(s, body) when s in 200..299 do
    ok_or_error(body, fn _b -> %{"ok" => true} end)
  end

  # ─── user.set_status — POST /users.profile.set ────────────────────────

  # The vendor body nests the three status fields under `profile`. A
  # missing `status_expiration` defaults to 0 ("no expiration") to
  # match Slack's documented semantics.
  defp user_set_status_request(args, _ctx) do
    profile =
      %{"status_text" => args["status_text"]}
      |> Map.put("status_emoji", Map.get(args, "status_emoji", ""))
      |> Map.put("status_expiration", Map.get(args, "status_expiration", 0))

    [json: %{"profile" => profile}]
  end

  defp user_set_status_response(s, body) when s in 200..299 do
    ok_or_error(body, fn _b -> %{"ok" => true} end)
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  # Slack returns HTTP 200 even on failure. Branch on the `"ok"` field:
  # success runs the per-function mapper; failure surfaces the raw error
  # body so the connector's `remap_error/1` owns vendor → canonical
  # classification.
  defp ok_or_error(%{"ok" => true} = body, map_fun) when is_function(map_fun, 1) do
    {:ok, map_fun.(body)}
  end

  defp ok_or_error(%{"ok" => false} = body, _map_fun) do
    {:error, body}
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
