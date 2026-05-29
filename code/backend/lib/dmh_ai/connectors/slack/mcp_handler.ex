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
    channel.find       — GET  /conversations.list
    channel.history    — GET  /conversations.history
    message.find       — GET  /search.messages
    user.find_by_email — GET  /users.lookupByEmail
    user.list          — GET  /users.list
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
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec
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
