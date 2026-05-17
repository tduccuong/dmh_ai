# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Calendly.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Calendly connector consumed by the
  generic `Connectors.MCPServer`. Each function is a 1:1 mapping
  to a Calendly v2 endpoint at `api.calendly.com/*`:

    user.me                    — GET /users/me
    event_type.list            — GET /event_types?user={uri}
    event_type.available_slots — GET /event_type_available_times
    event.list                 — GET /scheduled_events?user={uri}
    event.invitees             — GET /scheduled_events/{uuid}/invitees
    single_use_link.create     — POST /scheduling_links
    event.cancel               — POST /scheduled_events/{uuid}/cancellation
    event.mark_no_show         — POST /invitee_no_shows

  Calendly's API is URI-centric — every resource is identified by
  a full URL (e.g. `https://api.calendly.com/event_types/AAAA…`),
  not a short UUID. We pass these through verbatim; arguments
  named `*_uri` always carry the full URL the previous read
  returned. This keeps round-tripping deterministic (no
  re-construction of URIs from UUIDs) at the cost of slightly
  longer argument strings.

  ## Per-user URI resolution

  Most list endpoints require `user={uri}` as a query parameter
  (Calendly's API is multi-tenant; you must scope queries to the
  connected user). The handler fetches `/users/me` lazily and
  caches the result in the request context to avoid a round-trip
  per call. The `user.me` function exposes the same call to the
  agent for explicit "whoami" prompts.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  require Logger

  @api_base "https://api.calendly.com"

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "calendly", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "user.me" => %FunctionSpec{
        method:   :get,
        url:      "#{@api_base}/users/me",
        request:  fn _args, _ctx -> [] end,
        response: &user_me_response/2,
        doc:      "Identity of the connected Calendly account."
      },
      "event_type.list" => %FunctionSpec{
        handler: &event_type_list/2,
        doc:     "List the connected user's event types (scheduling links)."
      },
      "event_type.available_slots" => %FunctionSpec{
        method:   :get,
        url:      "#{@api_base}/event_type_available_times",
        request:  &event_type_available_slots_request/2,
        response: &event_type_available_slots_response/2,
        doc:      "Open booking slots for an event type in a time window."
      },
      "event.list" => %FunctionSpec{
        handler: &event_list/2,
        doc:     "List scheduled meetings (optionally filtered by window / status)."
      },
      "event.invitees" => %FunctionSpec{
        handler: &event_invitees/2,
        doc:     "List invitees on a scheduled event."
      },
      "single_use_link.create" => %FunctionSpec{
        method:   :post,
        url:      "#{@api_base}/scheduling_links",
        request:  &single_use_link_create_request/2,
        response: &single_use_link_create_response/2,
        doc:      "Create a one-time scheduling link to send to a contact."
      },
      "event.cancel" => %FunctionSpec{
        handler: &event_cancel/2,
        doc:     "Cancel a scheduled meeting."
      },
      "event.mark_no_show" => %FunctionSpec{
        method:   :post,
        url:      "#{@api_base}/invitee_no_shows",
        request:  &event_mark_no_show_request/2,
        response: &event_mark_no_show_response/2,
        doc:      "Record an invitee as a no-show."
      }
    }
  end

  # ─── user.me ──────────────────────────────────────────────────────────

  defp user_me_response(s, body) when s in 200..299 do
    res = Map.get(body, "resource", %{})

    {:ok,
     %{
       "user" => %{
         "uri"      => res["uri"],
         "name"     => res["name"],
         "email"    => res["email"],
         "timezone" => res["timezone"],
         "scheduling_url" => res["scheduling_url"]
       }
     }}
  end

  # ─── event_type.list — needs user URI, so handler-style ───────────────

  defp event_type_list(args, ctx) do
    with {:ok, user_uri} <- resolve_user_uri(ctx) do
      query = [
        {"user", user_uri},
        {"count", to_string(Map.get(args, "limit", 25))}
      ]

      query =
        case Map.get(args, "active_only") do
          true  -> query ++ [{"active", "true"}]
          false -> query ++ [{"active", "false"}]
          _     -> query
        end

      url = "#{@api_base}/event_types?" <> URI.encode_query(query)

      case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
        {:ok, status, body} when status in 200..299 ->
          types =
            body
            |> Map.get("collection", [])
            |> Enum.map(&normalise_event_type/1)

          {:ok, %{"event_types" => types}}

        {:ok, status, body} ->
          {:error, {:http, status, body}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp normalise_event_type(et) do
    %{
      "uri"             => et["uri"],
      "name"            => et["name"],
      "slug"            => et["slug"],
      "duration"        => et["duration"],
      "active"          => et["active"],
      "scheduling_url"  => et["scheduling_url"]
    }
  end

  # ─── event_type.available_slots ───────────────────────────────────────

  defp event_type_available_slots_request(args, _ctx) do
    [
      params: [
        {"event_type", args["event_type_uri"]},
        {"start_time", args["start_time"]},
        {"end_time",   args["end_time"]}
      ]
    ]
  end

  defp event_type_available_slots_response(s, body) when s in 200..299 do
    slots =
      body
      |> Map.get("collection", [])
      |> Enum.map(fn slot ->
        %{
          "start_time"    => slot["start_time"],
          "status"        => slot["status"],
          "scheduling_url" => slot["scheduling_url"]
        }
      end)

    {:ok, %{"slots" => slots}}
  end

  # ─── event.list — needs user URI ──────────────────────────────────────

  defp event_list(args, ctx) do
    with {:ok, user_uri} <- resolve_user_uri(ctx) do
      query =
        [{"user", user_uri}, {"count", to_string(Map.get(args, "limit", 25))}]
        |> maybe_add_query("min_start_time", Map.get(args, "min_start_time"))
        |> maybe_add_query("max_start_time", Map.get(args, "max_start_time"))
        |> maybe_add_query("status",         Map.get(args, "status"))

      url = "#{@api_base}/scheduled_events?" <> URI.encode_query(query)

      case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
        {:ok, status, body} when status in 200..299 ->
          events =
            body
            |> Map.get("collection", [])
            |> Enum.map(&normalise_event/1)

          {:ok, %{"events" => events}}

        {:ok, status, body} ->
          {:error, {:http, status, body}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp normalise_event(e) do
    %{
      "uri"        => e["uri"],
      "name"       => e["name"],
      "status"     => e["status"],
      "start_time" => e["start_time"],
      "end_time"   => e["end_time"],
      "location"   => get_in(e, ["location", "join_url"]) || get_in(e, ["location", "location"])
    }
  end

  # ─── event.invitees — dynamic URL from event_uri ──────────────────────

  defp event_invitees(args, ctx) do
    event_uri = args["event_uri"]
    limit     = Map.get(args, "limit", 25)

    # event_uri is e.g. "https://api.calendly.com/scheduled_events/AAAA-BBBB"
    # → invitees live at "{event_uri}/invitees"
    url = event_uri <> "/invitees?" <> URI.encode_query([{"count", to_string(limit)}])

    case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
      {:ok, status, body} when status in 200..299 ->
        invitees =
          body
          |> Map.get("collection", [])
          |> Enum.map(fn iv ->
            %{
              "uri"     => iv["uri"],
              "name"    => iv["name"],
              "email"   => iv["email"],
              "status"  => iv["status"],
              "responses" => Map.get(iv, "questions_and_answers", [])
            }
          end)

        {:ok, %{"invitees" => invitees}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── single_use_link.create ───────────────────────────────────────────

  defp single_use_link_create_request(args, _ctx) do
    body =
      %{
        "owner"            => args["event_type_uri"],
        "owner_type"       => "EventType",
        "max_event_count"  => Map.get(args, "max_event_count", 1)
      }

    [json: body]
  end

  defp single_use_link_create_response(s, body) when s in 200..299 do
    res = Map.get(body, "resource", %{})

    {:ok,
     %{
       "booking_url" => res["booking_url"],
       "owner"       => res["owner"]
     }}
  end

  # ─── event.cancel — dynamic URL from event_uri ────────────────────────

  defp event_cancel(args, ctx) do
    event_uri = args["event_uri"]
    reason    = Map.get(args, "reason", "")

    url = event_uri <> "/cancellation"

    body =
      case reason do
        r when is_binary(r) and r != "" -> %{"reason" => r}
        _                                -> %{}
      end

    case RestBridge.raw_request(:post, with_bearer([url: url, json: body], ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{"cancelled" => true, "event_uri" => event_uri}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── event.mark_no_show ───────────────────────────────────────────────

  defp event_mark_no_show_request(args, _ctx) do
    [json: %{"invitee" => args["invitee_uri"]}]
  end

  defp event_mark_no_show_response(s, body) when s in 200..299 do
    res = Map.get(body, "resource", %{})

    {:ok,
     %{
       "marked"      => true,
       "no_show_uri" => res["uri"],
       "invitee_uri" => res["invitee"]
     }}
  end

  # ─── User URI resolution (cached per-call by RestBridge ctx) ──────────

  # Many Calendly endpoints require `user={uri}` scoping. We lazily
  # fetch /users/me once per call-chain and stash the URI in the
  # ctx map. Callers that already have the URI (e.g. cross-task
  # follow-ups) can pre-populate `ctx[:__calendly_user_uri]` to
  # skip the roundtrip.
  defp resolve_user_uri(%{__calendly_user_uri: uri}) when is_binary(uri) and uri != "" do
    {:ok, uri}
  end

  defp resolve_user_uri(ctx) do
    url = "#{@api_base}/users/me"

    case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
      {:ok, status, body} when status in 200..299 ->
        case get_in(body, ["resource", "uri"]) do
          uri when is_binary(uri) and uri != "" -> {:ok, uri}
          _ -> {:error, {:http, 500, "users/me returned no uri"}}
        end

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  defp with_bearer(opts, %{bearer_token: t}) when is_binary(t) and t != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"authorization", "Bearer " <> t} | headers])
  end
  defp with_bearer(opts, _), do: opts

  defp maybe_add_query(list, _k, nil), do: list
  defp maybe_add_query(list, _k, ""),  do: list
  defp maybe_add_query(list, k, v),    do: list ++ [{k, to_string(v)}]
end
