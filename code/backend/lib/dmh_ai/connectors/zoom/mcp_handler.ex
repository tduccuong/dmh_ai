# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Zoom.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Zoom connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a Zoom
  REST endpoint at `https://api.zoom.us/v2/*`:

    meeting.create — POST   /users/me/meetings
    meeting.find   — GET    /users/me/meetings
    meeting.get    — GET    /meetings/{meeting_id}
    meeting.update — PATCH  /meetings/{meeting_id}
    meeting.delete — DELETE /meetings/{meeting_id}
    recording.find — GET    /users/me/recordings
    user.find      — GET    /users/{user_id_or_me}
    webinar.create — POST   /users/me/webinars

  Fixed host (`https://api.zoom.us/v2`), no per-instance templating.
  Standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## Path-param ids

  Zoom targets the authed user with the literal path segment `me`
  (`/users/me/meetings`). Functions acting on a specific object
  interpolate the id into the path via a `:url` function `(args ->
  url)`. The id is whitelisted to `^[A-Za-z0-9_-]+$` before the URL
  is built (`safe_path_id/1`) — no raw interpolation of unvalidated
  input. `user.find` defaults the path segment to `me` when the
  optional `user_id` arg is absent.

  ## Numeric error codes

  Unlike Slack's HTTP-200-on-failure model, Zoom returns normal HTTP
  status codes; the `RestBridge` keys success off the 2xx status. On a
  4xx/5xx Zoom frames a JSON body `%{"code" => <int>, "message" =>
  ...}` which the bridge surfaces and the connector's `remap_error/1`
  maps to the canonical class. `meeting.update` (PATCH) and
  `meeting.delete` (DELETE) answer 204 No Content on success — their
  `response` parsers echo a fixed shape since there is no body to read.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec
  require Logger

  @api_base "https://api.zoom.us/v2"

  # Zoom object ids are numeric / short alphanumeric strings. Whitelist
  # the charset before interpolating into a URL path so an attacker
  # can't inject path segments or query strings via a lookup arg.
  @path_id_re ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "zoom", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "meeting.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/users/me/meetings",
        request: &meeting_create_request/2,
        response: &meeting_create_response/2,
        doc:     "Schedule a meeting for the authed user."
      },
      "meeting.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/users/me/meetings",
        request: &meeting_find_request/2,
        response: &meeting_find_response/2,
        doc:     "List the authed user's meetings."
      },
      "meeting.get" => %FunctionSpec{
        method:  :get,
        url:     &meeting_get_url/1,
        response: &meeting_get_response/2,
        doc:     "Read one meeting by id."
      },
      "meeting.update" => %FunctionSpec{
        method:  :patch,
        url:     &meeting_update_url/1,
        request: &meeting_update_request/2,
        response: &meeting_update_response/2,
        doc:     "Patch meeting fields (topic, start_time, duration, …)."
      },
      "meeting.delete" => %FunctionSpec{
        method:  :delete,
        url:     &meeting_delete_url/1,
        request: fn _args, _ctx -> [] end,
        response: &meeting_delete_response/2,
        doc:     "Delete a meeting."
      },
      "recording.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/users/me/recordings",
        request: &recording_find_request/2,
        response: &recording_find_response/2,
        doc:     "List the authed user's cloud recordings."
      },
      "user.find" => %FunctionSpec{
        method:  :get,
        url:     &user_find_url/1,
        response: &user_find_response/2,
        doc:     "Read a user (defaults to the authed user)."
      },
      "webinar.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/users/me/webinars",
        request: &webinar_create_request/2,
        response: &webinar_create_response/2,
        doc:     "Schedule a webinar for the authed user."
      }
    }
  end

  # ─── meeting.create — POST /users/me/meetings ─────────────────────────

  defp meeting_create_request(args, _ctx) do
    body =
      %{"topic" => args["topic"]}
      |> maybe_put_kv("start_time", Map.get(args, "start_time"))
      |> maybe_put_kv("duration",   Map.get(args, "duration"))
      |> maybe_put_kv("agenda",     Map.get(args, "agenda"))

    [json: body]
  end

  defp meeting_create_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "meeting_id" => to_string(body["id"]),
       "join_url"   => body["join_url"]
     }}
  end

  # ─── meeting.find — GET /users/me/meetings ────────────────────────────

  defp meeting_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "page_size", Map.get(args, "limit"))
    [params: params]
  end

  defp meeting_find_response(s, body) when s in 200..299 do
    {:ok, %{"meetings" => Map.get(body, "meetings", [])}}
  end

  # ─── meeting.get — GET /meetings/{meeting_id} ─────────────────────────

  defp meeting_get_url(args), do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}"

  defp meeting_get_response(s, body) when s in 200..299 do
    {:ok, %{"meeting" => body}}
  end

  # ─── meeting.update — PATCH /meetings/{meeting_id} ────────────────────

  defp meeting_update_url(args), do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}"

  defp meeting_update_request(args, _ctx) do
    [json: args["patch"] || %{}]
  end

  # Zoom PATCH on a meeting returns 204 No Content on success (no
  # body), so we don't read fields back — we echo the id.
  defp meeting_update_response(s, _body) when s in 200..299 do
    {:ok, %{"meeting_id" => "updated"}}
  end

  # ─── meeting.delete — DELETE /meetings/{meeting_id} ───────────────────

  defp meeting_delete_url(args), do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}"

  # Zoom DELETE on a meeting returns 204 No Content on success.
  defp meeting_delete_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── recording.find — GET /users/me/recordings ───────────────────────

  defp recording_find_request(args, _ctx) do
    params =
      %{}
      |> maybe_put_kv("from",      Map.get(args, "from"))
      |> maybe_put_kv("to",        Map.get(args, "to"))
      |> maybe_put_kv("page_size", Map.get(args, "limit"))

    [params: params]
  end

  defp recording_find_response(s, body) when s in 200..299 do
    {:ok, %{"recordings" => Map.get(body, "meetings", [])}}
  end

  # ─── user.find — GET /users/{user_id_or_me} ───────────────────────────

  # Default the path segment to `me` when the optional `user_id` arg is
  # absent; whitelist a provided id before interpolating it.
  defp user_find_url(args) do
    segment =
      case Map.get(args, "user_id") do
        v when is_binary(v) and v != "" -> safe_path_id(v)
        _ -> "me"
      end

    "#{@api_base}/users/#{segment}"
  end

  defp user_find_response(s, body) when s in 200..299 do
    {:ok, %{"user" => body}}
  end

  # ─── webinar.create — POST /users/me/webinars ─────────────────────────

  defp webinar_create_request(args, _ctx) do
    body =
      %{"topic" => args["topic"]}
      |> maybe_put_kv("start_time", Map.get(args, "start_time"))
      |> maybe_put_kv("duration",   Map.get(args, "duration"))

    [json: body]
  end

  defp webinar_create_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "webinar_id"       => to_string(body["id"]),
       "registration_url" => body["registration_url"]
     }}
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  # Whitelist a path-param id to the Zoom id charset before
  # interpolating it into a URL. A value that doesn't match raises —
  # the dispatcher surfaces it as an error envelope rather than
  # building a URL with an injected segment / query string.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid zoom id: #{inspect(id)}"
    end
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
