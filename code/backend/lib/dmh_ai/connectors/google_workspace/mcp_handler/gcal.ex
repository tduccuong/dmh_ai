# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Gcal do
  @moduledoc """
  Google Calendar surface — `gcal.find_free_slots`, `gcal.list_events`,
  `gcal.create_event`, `gcal.update_event`, `gcal.delete_event`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.GoogleWorkspace.MCPHandler.Helpers

  @calendar_base "https://www.googleapis.com/calendar/v3"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "gcal.find_free_slots" => %FunctionSpec{
        handler: &gcal_find_free_slots/2,
        doc:     "List free slots of `duration_min` length within a window."
      },
      "gcal.list_events" => %FunctionSpec{
        method:  :get,
        url:     "#{@calendar_base}/calendars/primary/events",
        request: &gcal_list_events_request/2,
        response: fn 200, body -> {:ok, %{"events" => Map.get(body, "items", [])}}
                    s, _b when s in 200..299 -> {:ok, %{"events" => []}} end,
        doc:     "List Calendar events on the primary calendar within a window (recurring events expanded)."
      },
      "gcal.create_event" => %FunctionSpec{
        method:  :post,
        url:     "#{@calendar_base}/calendars/primary/events",
        request: &gcal_create_event_request/2,
        response: fn 200, body -> {:ok, %{"event_id" => body["id"], "html_link" => body["htmlLink"]}}
                    s, _b when s in 200..299 -> {:ok, %{}} end,
        doc:     "Create a Calendar event on the primary calendar."
      },
      "gcal.update_event" => %FunctionSpec{
        handler: &gcal_update_event/2,
        doc:     "Move / reschedule / rename an existing Calendar event."
      },
      "gcal.delete_event" => %FunctionSpec{
        handler: &gcal_delete_event/2,
        doc:     "Delete a Calendar event from the named calendar (defaults to 'primary')."
      }
    }
  end

  # ─── gcal.find_free_slots — freebusy.query + slot computation ─────────

  # vendor: POST /calendar/v3/freeBusy
  # Returns busy intervals; the shim computes free slots of
  # `duration_min` length within `[between_from, between_to]`.
  defp gcal_find_free_slots(args, ctx) do
    body = %{
      "timeMin" => args["between_from"],
      "timeMax" => args["between_to"],
      "items"   => [%{"id" => "primary"}]
    }

    case Helpers.bare_post("#{@calendar_base}/freeBusy", body, ctx) do
      {:ok, %{"calendars" => %{"primary" => %{"busy" => busy}}}} ->
        slots =
          compute_free_slots(
            args["between_from"],
            args["between_to"],
            Map.get(args, "duration_min", 30),
            busy
          )

        {:ok, %{"slots" => slots}}

      {:ok, _} ->
        {:ok, %{"slots" => []}}

      err ->
        err
    end
  end

  # Walk the [from, to] window, skipping over busy intervals; emit
  # every (start, start+duration) pair where start+duration ≤ next
  # busy boundary. Naive but adequate for the function's contract; if
  # SMEs need ranked slots / preferences, that's a separate function.
  defp compute_free_slots(from_iso, to_iso, duration_min, busy_intervals) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from_iso),
         {:ok, to_dt, _}   <- DateTime.from_iso8601(to_iso) do
      busy =
        busy_intervals
        |> Enum.map(fn %{"start" => bs, "end" => be} ->
          {:ok, bs_dt, _} = DateTime.from_iso8601(bs)
          {:ok, be_dt, _} = DateTime.from_iso8601(be)
          {bs_dt, be_dt}
        end)
        |> Enum.sort_by(&elem(&1, 0), DateTime)

      duration_s = duration_min * 60

      walk_slots(from_dt, to_dt, duration_s, busy, [])
      |> Enum.reverse()
    else
      _ -> []
    end
  end

  defp walk_slots(cursor, to_dt, dur_s, busy, acc) do
    cond do
      DateTime.compare(DateTime.add(cursor, dur_s, :second), to_dt) == :gt ->
        acc

      true ->
        slot_end = DateTime.add(cursor, dur_s, :second)
        next_busy_start = next_busy_start(busy, cursor)

        cond do
          # Cursor falls inside a busy interval → jump to its end.
          inside_busy?(cursor, busy) ->
            new_cursor = first_busy_containing(busy, cursor) |> elem(1)
            walk_slots(new_cursor, to_dt, dur_s, busy, acc)

          # Slot end would overlap the next busy → jump cursor past it.
          next_busy_start != nil and
              DateTime.compare(slot_end, next_busy_start) == :gt ->
            walk_slots(next_busy_start, to_dt, dur_s, busy, acc)

          true ->
            slot = %{
              "start"        => DateTime.to_iso8601(cursor),
              "end"          => DateTime.to_iso8601(slot_end),
              "duration_min" => div(dur_s, 60)
            }

            # Advance by full duration to next candidate slot.
            walk_slots(slot_end, to_dt, dur_s, busy, [slot | acc])
        end
    end
  end

  defp inside_busy?(dt, busy) do
    Enum.any?(busy, fn {bs, be} ->
      DateTime.compare(dt, bs) != :lt and DateTime.compare(dt, be) == :lt
    end)
  end

  defp first_busy_containing(busy, dt) do
    Enum.find(busy, fn {bs, be} ->
      DateTime.compare(dt, bs) != :lt and DateTime.compare(dt, be) == :lt
    end)
  end

  defp next_busy_start(busy, after_dt) do
    busy
    |> Enum.find(fn {bs, _be} -> DateTime.compare(bs, after_dt) != :lt end)
    |> case do
      nil      -> nil
      {bs, _}  -> bs
    end
  end

  # ─── gcal.create_event — events.insert ────────────────────────────────

  defp gcal_create_event_request(args, _ctx) do
    body = %{
      "summary" => args["title"],
      "start"   => %{"dateTime" => args["start"]},
      "end"     => %{"dateTime" => args["end"]},
      "attendees" => (args["attendees"] || []) |> Enum.map(fn email -> %{"email" => email} end)
    }

    [json: body]
  end

  # ─── gcal.list_events — events.list with window + chronological order ─

  # `singleEvents=true` + `orderBy=startTime` are the standard pairing:
  # recurring events expand into individual instances and the response
  # comes back chronological — what "list events between X and Y"
  # callers expect. Optional `q` / `maxResults` ride along when set.
  defp gcal_list_events_request(args, _ctx) do
    base = [
      {"timeMin",      args["time_min"]},
      {"timeMax",      args["time_max"]},
      {"singleEvents", "true"},
      {"orderBy",      "startTime"}
    ]

    params =
      base
      |> maybe_append_param("q",          Map.get(args, "query"))
      |> maybe_append_param("maxResults", Map.get(args, "max_results"))

    [params: params]
  end

  defp maybe_append_param(params, _k, nil), do: params
  defp maybe_append_param(params, _k, ""),  do: params
  defp maybe_append_param(params, k, v),    do: params ++ [{k, v}]

  # ─── gcal.update_event — PATCH with dynamic URL ───────────────────────

  defp gcal_update_event(args, ctx) do
    event_id = args["event_id"]
    patch    = Map.get(args, "patch") || %{}

    url = "#{@calendar_base}/calendars/primary/events/#{URI.encode(event_id)}"

    opts = [url: url, json: patch]

    case RestBridge.raw_request(:patch, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"event_id" => body["id"], "updated" => Map.keys(patch)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── gcal.delete_event — DELETE /calendars/{cal_id}/events/{event_id} ─

  # vendor: DELETE /calendar/v3/calendars/{calendar_id}/events/{event_id}
  # docs:   https://developers.google.com/calendar/api/v3/reference/events/delete
  defp gcal_delete_event(args, ctx) do
    event_id    = Helpers.safe_path_id(args["event_id"])
    calendar_id = Helpers.safe_path_id(Map.get(args, "calendar_id") || "primary")

    url = "#{@calendar_base}/calendars/#{calendar_id}/events/#{event_id}"

    case RestBridge.raw_request(:delete, Helpers.with_bearer([url: url], ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{"ok" => true}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end
end
