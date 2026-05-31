# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Cal do
  @moduledoc """
  Outlook Calendar surface — `cal.find_free_slots`, `cal.create_event`,
  `cal.update_event`, `cal.list_events`. `find_free_slots` calls
  Graph's `getSchedule` (which returns BUSY intervals) and computes
  free slots client-side; the rest map 1:1 to Graph endpoints.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "cal.find_free_slots" => %FunctionSpec{
        handler: &cal_find_free_slots/2,
        doc:     "List free slots of `duration_min` length within a window. Uses getSchedule."
      },
      "cal.create_event" => %FunctionSpec{
        method:  :post,
        url:     "#{@graph_base}/events",
        request: &cal_create_event_request/2,
        response: fn 201, body -> {:ok, %{"event_id" => body["id"], "web_link" => body["webLink"]}}
                    s,   _b   when s in 200..299 -> {:ok, %{}} end,
        doc:     "Create an Outlook calendar event."
      },
      "cal.update_event" => %FunctionSpec{
        handler: &cal_update_event/2,
        doc:     "Patch an existing calendar event (reschedule, rename, …)."
      },
      "cal.list_events" => %FunctionSpec{
        handler: &cal_list_events/2,
        doc:     "List Outlook calendar events between two timestamps (optionally KQL-filtered)."
      }
    }
  end

  # ─── cal.find_free_slots — getSchedule + slot computation ─────────────

  # vendor: POST /v1.0/me/calendar/getSchedule
  # body: {schedules: [email], startTime: {dateTime, timeZone}, endTime: {dateTime, timeZone}, availabilityViewInterval: 30}
  # response: {value: [{scheduleId, busyViewType, scheduleItems: [{status: "busy", start, end}]}]}
  defp cal_find_free_slots(args, ctx) do
    duration_min = Map.get(args, "duration_min", 30)
    from_iso     = args["between_from"]
    to_iso       = args["between_to"]
    attendees    = Map.get(args, "attendees", []) || []

    # Single-user lookup if no attendees specified — use "me" (Graph
    # resolves to the calling user's mailbox).
    schedules =
      case attendees do
        []   -> [user_email_from_ctx(ctx) || "me"]
        list -> list
      end

    body = %{
      "schedules" => schedules,
      "startTime" => %{"dateTime" => from_iso, "timeZone" => "UTC"},
      "endTime"   => %{"dateTime" => to_iso,   "timeZone" => "UTC"},
      "availabilityViewInterval" => 30
    }

    case RestBridge.raw_request(:post, Helpers.with_bearer([url: "#{@graph_base}/calendar/getSchedule", json: body], ctx)) do
      {:ok, 200, %{"value" => entries}} when is_list(entries) ->
        busy = collect_busy_intervals(entries)
        slots = compute_free_slots(from_iso, to_iso, duration_min, busy)
        {:ok, %{"slots" => slots}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp user_email_from_ctx(_ctx), do: nil

  defp collect_busy_intervals(entries) do
    entries
    |> Enum.flat_map(fn e ->
      Map.get(e, "scheduleItems", [])
      |> Enum.filter(fn item -> Map.get(item, "status") == "busy" end)
      |> Enum.map(fn item ->
        {parse_dt(item["start"]), parse_dt(item["end"])}
      end)
    end)
    |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
    |> Enum.sort_by(fn {a, _} -> a end, DateTime)
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(%{"dateTime" => dt}) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, d, _} -> d
      _ ->
        # Graph returns naive datetime (no Z) for getSchedule; assume UTC.
        case NaiveDateTime.from_iso8601(dt) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _            -> nil
        end
    end
  end
  defp parse_dt(_), do: nil

  defp compute_free_slots(from_iso, to_iso, duration_min, busy) do
    with {:ok, win_from, _} <- DateTime.from_iso8601(from_iso),
         {:ok, win_to,   _} <- DateTime.from_iso8601(to_iso) do
      duration_s = duration_min * 60

      # Linear sweep — gap > duration between adjacent busy intervals
      # within the window is a free slot. Bounds: [win_from, win_to].
      points =
        [{win_from, win_from}] ++ busy ++ [{win_to, win_to}]
        |> Enum.sort_by(fn {a, _} -> a end, DateTime)

      points
      |> Enum.zip(Enum.drop(points, 1))
      |> Enum.flat_map(fn {{_, prev_end}, {next_start, _}} ->
        gap = DateTime.diff(next_start, prev_end)
        if gap >= duration_s do
          [%{
            "start" => DateTime.to_iso8601(prev_end),
            "end"   => DateTime.to_iso8601(DateTime.add(prev_end, duration_s, :second))
          }]
        else
          []
        end
      end)
    else
      _ -> []
    end
  end

  # ─── cal.create_event — POST /me/events ───────────────────────────────

  defp cal_create_event_request(args, _ctx) do
    attendees =
      (args["attendees"] || [])
      |> Enum.map(fn email ->
        %{"emailAddress" => %{"address" => email}, "type" => "required"}
      end)

    [
      json: %{
        "subject"   => args["title"],
        "start"     => %{"dateTime" => args["start"], "timeZone" => "UTC"},
        "end"       => %{"dateTime" => args["end"],   "timeZone" => "UTC"},
        "attendees" => attendees
      }
    ]
  end

  # ─── cal.update_event — PATCH /me/events/{id} ─────────────────────────

  defp cal_update_event(args, ctx) do
    event_id = args["event_id"]
    patch    = Map.get(args, "patch") || %{}

    url = "#{@graph_base}/events/#{URI.encode(event_id)}"

    case RestBridge.raw_request(:patch, Helpers.with_bearer([url: url, json: patch], ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"event_id" => body["id"], "updated" => Map.keys(patch)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── cal.list_events — GET /me/calendar/calendarView ──────────────────
  # vendor: GET /v1.0/me/calendar/calendarView?startDateTime=…&endDateTime=…
  #         &$top=N[&$search="<q>"]
  # Graph's calendarView expands recurrences into individual instances
  # within the window, which is what an SME wants when asking "what's
  # on my calendar next week".

  defp cal_list_events(args, ctx) do
    time_min = args["time_min"]
    time_max = args["time_max"]
    limit    = Map.get(args, "limit", 25)
    query    = Map.get(args, "query")

    params =
      [
        {"startDateTime", time_min},
        {"endDateTime",   time_max},
        {"$top",          limit},
        {"$select",       "id,subject,start,end,location,organizer,attendees,webLink"}
      ]
      |> maybe_add_search(query)

    opts = [
      url:     "#{@graph_base}/calendar/calendarView",
      params:  params,
      headers: search_headers(query)
    ]

    case RestBridge.raw_request(:get, Helpers.with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => raw}} when is_list(raw) ->
        events = Enum.map(raw, &normalise_event/1)
        {:ok, %{"events" => events}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_add_search(params, nil), do: params
  defp maybe_add_search(params, ""),  do: params
  defp maybe_add_search(params, q) when is_binary(q),
    do: params ++ [{"$search", "\"#{q}\""}]

  defp search_headers(q) when is_binary(q) and q != "",
    do: [{"consistencylevel", "eventual"}]
  defp search_headers(_), do: []

  defp normalise_event(%{} = e) do
    %{
      "id"       => e["id"],
      "subject"  => e["subject"],
      "start"    => get_in(e, ["start", "dateTime"]),
      "end"      => get_in(e, ["end",   "dateTime"]),
      "location" => get_in(e, ["location", "displayName"]),
      "organizer" => get_in(e, ["organizer", "emailAddress", "address"]),
      "web_link" => e["webLink"]
    }
  end
end
