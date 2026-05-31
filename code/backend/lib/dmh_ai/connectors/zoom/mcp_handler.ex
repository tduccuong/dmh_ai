# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Zoom.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Zoom connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a Zoom
  REST endpoint at `https://api.zoom.us/v2/*`:

    meeting.create            — POST   /users/me/meetings
    meeting.find              — GET    /users/me/meetings
    meeting.get               — GET    /meetings/{meeting_id}
    meeting.update            — PATCH  /meetings/{meeting_id}
    meeting.delete            — DELETE /meetings/{meeting_id}
    meeting.list_registrants  — GET    /meetings/{meeting_id}/registrants
    meeting.add_registrant    — POST   /meetings/{meeting_id}/registrants
    meeting.list_participants — GET    /report/meetings/{meeting_uuid}/participants
    recording.find            — GET    /users/me/recordings
    recording.get             — GET    /meetings/{meeting_id}/recordings
    recording.delete          — DELETE /meetings/{meeting_id}/recordings
    user.find                 — GET    /users/{user_id_or_me}
    user.find_by_email        — GET    /users/{email}
    webinar.create            — POST   /users/me/webinars
    webinar.find              — GET    /users/me/webinars
    webinar.add_registrant    — POST   /webinars/{webinar_id}/registrants
    webinar.update            — PATCH  /webinars/{webinar_id}

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

  ## Meeting UUIDs are URI-encoded, not whitelisted

  `meeting.list_participants` keys off Zoom's meeting `uuid` (not its
  numeric id). UUIDs may contain `/` and `+`, which the standard
  whitelist would reject. They are passed through `URI.encode_www_form/1`
  before interpolation — `/` becomes `%2F`, `+` becomes `%2B`. The
  Zoom docs explicitly call out the double-encoding requirement for
  uuids beginning with `/` or containing `//`; the canonical
  workaround is the same `URI.encode_www_form/1` pass applied twice
  (handled inside `safe_meeting_uuid/1`).

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
      },
      "meeting.list_registrants" => %FunctionSpec{
        method:  :get,
        url:     &meeting_list_registrants_url/1,
        request: &meeting_list_registrants_request/2,
        response: &meeting_list_registrants_response/2,
        doc:     "List registrants for a meeting."
      },
      "meeting.add_registrant" => %FunctionSpec{
        method:  :post,
        url:     &meeting_add_registrant_url/1,
        request: &meeting_add_registrant_request/2,
        response: &meeting_add_registrant_response/2,
        doc:     "Add a registrant to a meeting."
      },
      "meeting.list_participants" => %FunctionSpec{
        method:  :get,
        url:     &meeting_list_participants_url/1,
        request: &meeting_list_participants_request/2,
        response: &meeting_list_participants_response/2,
        doc:     "List participants of a past meeting (Reports API)."
      },
      "recording.get" => %FunctionSpec{
        method:  :get,
        url:     &recording_get_url/1,
        response: &recording_get_response/2,
        doc:     "Read recording files for one meeting."
      },
      "recording.delete" => %FunctionSpec{
        method:  :delete,
        url:     &recording_delete_url/1,
        request: &recording_delete_request/2,
        response: &recording_delete_response/2,
        doc:     "Trash or permanently delete cloud recordings for one meeting."
      },
      "webinar.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/users/me/webinars",
        request: &webinar_find_request/2,
        response: &webinar_find_response/2,
        doc:     "List the authed user's webinars."
      },
      "webinar.add_registrant" => %FunctionSpec{
        method:  :post,
        url:     &webinar_add_registrant_url/1,
        request: &webinar_add_registrant_request/2,
        response: &webinar_add_registrant_response/2,
        doc:     "Add a registrant to a webinar."
      },
      "webinar.update" => %FunctionSpec{
        method:  :patch,
        url:     &webinar_update_url/1,
        request: &webinar_update_request/2,
        response: &webinar_update_response/2,
        doc:     "Patch webinar fields (topic, start_time, duration, …)."
      },
      "user.find_by_email" => %FunctionSpec{
        method:  :get,
        url:     &user_find_by_email_url/1,
        response: &user_find_by_email_response/2,
        doc:     "Look up a Zoom user by email (GET /users/{email}). Identity pivot."
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

  # ─── meeting.list_registrants — GET /meetings/{meeting_id}/registrants ─

  defp meeting_list_registrants_url(args),
    do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}/registrants"

  defp meeting_list_registrants_request(args, _ctx) do
    params =
      %{}
      |> maybe_put_kv("status",    Map.get(args, "status"))
      |> maybe_put_kv("page_size", Map.get(args, "limit"))

    [params: params]
  end

  defp meeting_list_registrants_response(s, body) when s in 200..299 do
    {:ok, %{"registrants" => Map.get(body, "registrants", [])}}
  end

  # ─── meeting.add_registrant — POST /meetings/{meeting_id}/registrants ─

  defp meeting_add_registrant_url(args),
    do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}/registrants"

  defp meeting_add_registrant_request(args, _ctx) do
    body =
      %{
        "email"      => args["email"],
        "first_name" => args["first_name"]
      }
      |> maybe_put_kv("last_name", Map.get(args, "last_name"))

    [json: body]
  end

  defp meeting_add_registrant_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "registrant_id" => to_string(body["registrant_id"] || body["id"] || ""),
       "join_url"      => body["join_url"]
     }}
  end

  # ─── meeting.list_participants — GET /report/meetings/{uuid}/participants

  # Reports API. The `meeting_uuid` is passed through `safe_meeting_uuid/1`
  # — Zoom UUIDs may contain `/` and `+`, so they must be URI-encoded
  # (and double-encoded when they start with `/` or contain `//`) rather
  # than rejected by the whitelist.
  defp meeting_list_participants_url(args) do
    uuid = safe_meeting_uuid(args["meeting_uuid"])
    "#{@api_base}/report/meetings/#{uuid}/participants"
  end

  defp meeting_list_participants_request(args, _ctx) do
    params = maybe_put_kv(%{}, "page_size", Map.get(args, "limit"))
    [params: params]
  end

  defp meeting_list_participants_response(s, body) when s in 200..299 do
    {:ok, %{"participants" => Map.get(body, "participants", [])}}
  end

  # ─── recording.get — GET /meetings/{meeting_id}/recordings ────────────

  defp recording_get_url(args),
    do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}/recordings"

  defp recording_get_response(s, body) when s in 200..299 do
    {:ok, %{"recording" => body}}
  end

  # ─── recording.delete — DELETE /meetings/{meeting_id}/recordings ──────

  defp recording_delete_url(args),
    do: "#{@api_base}/meetings/#{safe_path_id(args["meeting_id"])}/recordings"

  defp recording_delete_request(args, _ctx) do
    params = maybe_put_kv(%{}, "action", Map.get(args, "action"))
    [params: params]
  end

  # Zoom answers 204 No Content on a successful recording delete.
  defp recording_delete_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── webinar.find — GET /users/me/webinars ────────────────────────────

  defp webinar_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "page_size", Map.get(args, "limit"))
    [params: params]
  end

  defp webinar_find_response(s, body) when s in 200..299 do
    {:ok, %{"webinars" => Map.get(body, "webinars", [])}}
  end

  # ─── webinar.add_registrant — POST /webinars/{webinar_id}/registrants ─

  defp webinar_add_registrant_url(args),
    do: "#{@api_base}/webinars/#{safe_path_id(args["webinar_id"])}/registrants"

  defp webinar_add_registrant_request(args, _ctx) do
    body =
      %{
        "email"      => args["email"],
        "first_name" => args["first_name"]
      }
      |> maybe_put_kv("last_name", Map.get(args, "last_name"))

    [json: body]
  end

  defp webinar_add_registrant_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "registrant_id" => to_string(body["registrant_id"] || body["id"] || ""),
       "join_url"      => body["join_url"]
     }}
  end

  # ─── webinar.update — PATCH /webinars/{webinar_id} ────────────────────

  defp webinar_update_url(args),
    do: "#{@api_base}/webinars/#{safe_path_id(args["webinar_id"])}"

  defp webinar_update_request(args, _ctx) do
    [json: args["patch"] || %{}]
  end

  # Zoom PATCH on a webinar returns 204 No Content on success.
  defp webinar_update_response(s, _body) when s in 200..299 do
    {:ok, %{"webinar_id" => "updated"}}
  end

  # ─── user.find_by_email — GET /users/{email} ──────────────────────────

  # vendor: GET /v2/users/{email}
  # docs:   https://developers.zoom.us/docs/api/users/
  # Zoom's `/users/{id}` accepts the email as the path id (same
  # endpoint as the numeric userId path) and returns the full Zoom
  # user resource. The whole body is surfaced as `%{"user" => body}`
  # so downstream `{{N.user.id}}` references pick up the Zoom user id.
  defp user_find_by_email_url(args),
    do: "#{@api_base}/users/#{safe_email_segment(args["email"])}"

  defp user_find_by_email_response(s, body) when s in 200..299 do
    {:ok, %{"user" => body}}
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

  # Zoom meeting UUIDs are not numeric ids — they can include `/` and
  # `+`, which the standard `safe_path_id/1` whitelist would reject.
  # Encode rather than whitelist: URL-escape the uuid before
  # interpolating it. Per Zoom docs, a uuid that starts with `/` or
  # contains `//` must be double-encoded; we apply
  # `URI.encode_www_form/1` twice in those cases so `/` becomes `%252F`
  # at the wire.
  defp safe_meeting_uuid(uuid) do
    str = to_string(uuid)

    if String.starts_with?(str, "/") or String.contains?(str, "//") do
      str |> URI.encode_www_form() |> URI.encode_www_form()
    else
      URI.encode_www_form(str)
    end
  end

  # Emails used as a path segment go through `URI.encode_www_form/1`
  # rather than the strict `@path_id_re` whitelist — the whitelist
  # rejects `@` and `.`, and broadening it for one verb would also
  # broaden it for every numeric-id verb. `@` + `.` are URI-safe so
  # encoding is mostly a no-op, but `+` aliases (`klara+demo@…`) and
  # any unicode local-parts get correctly percent-encoded.
  defp safe_email_segment(email), do: URI.encode_www_form(to_string(email))

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
