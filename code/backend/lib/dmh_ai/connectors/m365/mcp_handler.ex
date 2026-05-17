# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Microsoft 365 connector consumed by the
  generic `Connectors.MCPServer`. Each function declares a
  `FunctionSpec` — most are 1:1 mappings to a Microsoft Graph v1
  endpoint; three need custom orchestration:

    * `mail.search` — Graph's `$search` requires a custom request
      builder (ConsistencyLevel: eventual header + KQL escaping)
      and a response normaliser that flattens nested
      `from.emailAddress.address` into a flat shape.

    * `cal.find_free_slots` — `getSchedule` returns BUSY intervals;
      we compute free slots client-side (same shape as the GW
      connector's freebusy → slots computation).

    * `files.upload` — Graph's small-file PUT path requires the
      raw bytes as the request body and a per-filename URL
      template.

  Vendor anchors per function match `Connectors.M365`'s manifest
  comments — same `# vendor: …` URL grounding.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  require Logger

  @graph_base "https://graph.microsoft.com/v1.0/me"

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "m365", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "mail.search" => %FunctionSpec{
        handler: &mail_search/2,
        doc:     "Search Outlook messages by KQL query, return id + from + subject + receivedDateTime."
      },
      "mail.send" => %FunctionSpec{
        method:  :post,
        url:     "#{@graph_base}/sendMail",
        request: &mail_send_request/2,
        # Graph's /sendMail returns 202 with no body. Surface a
        # plain "accepted: true" so the model can confirm send.
        response: fn 202, _ -> {:ok, %{"accepted" => true}}
                    s,   _ when s in 200..299 -> {:ok, %{"accepted" => true}} end,
        doc:     "Send a plain-text Outlook message."
      },
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
      "files.list" => %FunctionSpec{
        handler: &files_list/2,
        doc:     "List OneDrive children at root or under a path."
      },
      "files.upload" => %FunctionSpec{
        handler: &files_upload/2,
        doc:     "Upload a small (<4 MB) file to OneDrive root by name."
      },
      "teams.create_meeting" => %FunctionSpec{
        method:  :post,
        url:     "#{@graph_base}/onlineMeetings",
        request: &teams_create_meeting_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{
                      "join_url"   => body["joinWebUrl"],
                      "meeting_id" => body["id"],
                      "subject"    => body["subject"]
                    }}
                  end,
        doc: "Create a Teams online meeting and return the join URL."
      },
      "todo.list" => %FunctionSpec{
        handler: &todo_list/2,
        doc:     "List tasks on the user's default Microsoft To Do list."
      },
      "todo.create" => %FunctionSpec{
        handler: &todo_create/2,
        doc:     "Add a task to the user's default Microsoft To Do list."
      },
      "contacts.search" => %FunctionSpec{
        handler: &contacts_search/2,
        doc:     "Search the user's Outlook contacts; returns name + email pairs."
      },
      "excel.read_range" => %FunctionSpec{
        handler: &excel_read_range/2,
        doc:     "Read a cell range from an Excel workbook in OneDrive (A1 notation)."
      },
      "mail.reply" => %FunctionSpec{
        handler: &mail_reply/2,
        doc:     "Reply to an Outlook message (Graph preserves the conversation/thread)."
      },
      "cal.update_event" => %FunctionSpec{
        handler: &cal_update_event/2,
        doc:     "Patch an existing calendar event (reschedule, rename, …)."
      },
      "onenote.read_page" => %FunctionSpec{
        handler: &onenote_read_page/2,
        doc:     "Read a OneNote page's text content (HTML stripped to plain text)."
      }
    }
  end

  # ─── mail.search — KQL $search with ConsistencyLevel header ───────────

  # vendor: GET /v1.0/me/messages?$search="..."&$top=N&$select=...
  defp mail_search(args, ctx) do
    q     = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 10)

    # Graph requires this header for $search on messages.
    extra_headers = [{"consistencylevel", "eventual"}]

    opts = [
      url:     "#{@graph_base}/messages",
      params: [
        {"$search", "\"#{q}\""},
        {"$top",    limit},
        {"$select", "id,subject,from,receivedDateTime,bodyPreview"}
      ],
      headers: extra_headers
    ]

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => raw}} when is_list(raw) ->
        msgs =
          Enum.map(raw, fn m ->
            %{
              "id"          => m["id"],
              "from"        => get_in(m, ["from", "emailAddress", "address"]),
              "subject"     => m["subject"],
              "received_at" => m["receivedDateTime"],
              "snippet"     => m["bodyPreview"] || ""
            }
          end)

        {:ok, %{"messages" => msgs, "queried" => q}}

      {:ok, _status, body} ->
        {:error, :upstream_other}
        |> tap(fn _ -> Logger.warning("[M365] mail.search non-2xx: #{inspect(body)}") end)

      {:error, _} = err ->
        err
    end
  end

  # ─── mail.send — POST /me/sendMail ────────────────────────────────────

  defp mail_send_request(args, _ctx) do
    [
      json: %{
        "message" => %{
          "subject" => args["subject"],
          "body" => %{
            "contentType" => "Text",
            "content"     => args["body"]
          },
          "toRecipients" => [
            %{"emailAddress" => %{"address" => args["to"]}}
          ]
        },
        "saveToSentItems" => "true"
      }
    ]
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

    case RestBridge.raw_request(:post, with_bearer([url: "#{@graph_base}/calendar/getSchedule", json: body], ctx)) do
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

  # ─── files.list — root or path ────────────────────────────────────────

  # vendor: GET /v1.0/me/drive/root/children       (root)
  # vendor: GET /v1.0/me/drive/root:/<path>:/children
  defp files_list(args, ctx) do
    path  = Map.get(args, "path", "") |> to_string() |> String.trim()
    limit = Map.get(args, "limit", 25)

    url =
      case path do
        "" -> "#{@graph_base}/drive/root/children"
        _  -> "#{@graph_base}/drive/root:/#{URI.encode(path)}:/children"
      end

    opts = [url: url, params: [{"$top", limit}, {"$select", "id,name,size,file,folder,lastModifiedDateTime"}]]

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => items}} when is_list(items) ->
        flat = Enum.map(items, &normalise_drive_item/1)
        {:ok, %{"items" => flat}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_drive_item(item) do
    %{
      "id"            => item["id"],
      "name"          => item["name"],
      "size"          => item["size"],
      "kind"          => cond do
        Map.has_key?(item, "folder") -> "folder"
        Map.has_key?(item, "file")   -> "file"
        true                          -> "unknown"
      end,
      "last_modified" => item["lastModifiedDateTime"]
    }
  end

  # ─── files.upload — PUT raw bytes to /root:/<name>:/content ───────────

  defp files_upload(args, ctx) do
    name      = args["name"]
    content   = args["content"] || ""
    mime_type = Map.get(args, "mime_type", "application/octet-stream")

    url = "#{@graph_base}/drive/root:/#{URI.encode(name)}:/content"

    opts = [
      url:     url,
      body:    content,
      headers: [{"content-type", mime_type}]
    ]

    case RestBridge.raw_request(:put, with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"file_id" => body["id"], "name" => body["name"], "web_url" => body["webUrl"]}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── teams.create_meeting — POST /me/onlineMeetings ───────────────────

  defp teams_create_meeting_request(args, _ctx) do
    # Default to "ad-hoc meeting now → next hour" when args are
    # blank. Outlook's UI does the same — clicking "New Teams
    # meeting" with no times set creates an immediate room.
    now = DateTime.utc_now()
    start_iso = Map.get(args, "start") || DateTime.to_iso8601(now)
    end_iso   = Map.get(args, "end")   || DateTime.to_iso8601(DateTime.add(now, 3600, :second))
    subject   = Map.get(args, "subject", "Ad-hoc meeting")

    [
      json: %{
        "startDateTime" => start_iso,
        "endDateTime"   => end_iso,
        "subject"       => subject
      }
    ]
  end

  # ─── todo.list / todo.create — over the default list ─────────────────
  #
  # Microsoft To Do groups tasks into lists; every account has a
  # default "Tasks" list created automatically. We resolve it by
  # name ("Tasks") via GET /me/todo/lists?$filter=displayName eq 'Tasks'
  # on each call. Caching the list-id would shave one round-trip
  # but adds a stale-cache invalidation story not worth it yet.

  defp todo_list(args, ctx) do
    with {:ok, list_id} <- resolve_default_todo_list(ctx) do
      opts = [
        url:     "#{@graph_base}/todo/lists/#{list_id}/tasks",
        params:  [{"$top", Map.get(args, "limit", 25)}, {"$select", "id,title,body,dueDateTime,status"}]
      ]

      case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
        {:ok, 200, %{"value" => tasks}} when is_list(tasks) ->
          {:ok, %{"tasks" => Enum.map(tasks, &normalise_todo_task/1)}}

        {:ok, _status, _body} ->
          {:error, :upstream_other}

        {:error, _} = err ->
          err
      end
    end
  end

  defp todo_create(args, ctx) do
    with {:ok, list_id} <- resolve_default_todo_list(ctx) do
      body =
        %{"title" => args["title"]}
        |> maybe_put_kv("body", build_todo_body(Map.get(args, "body")))
        |> maybe_put_kv("dueDateTime", build_todo_due(Map.get(args, "due")))

      opts = [url: "#{@graph_base}/todo/lists/#{list_id}/tasks", json: body]

      case RestBridge.raw_request(:post, with_bearer(opts, ctx)) do
        {:ok, status, resp} when status in 200..299 ->
          {:ok, %{"task_id" => resp["id"], "title" => resp["title"]}}

        {:ok, _status, _body} ->
          {:error, :upstream_other}

        {:error, _} = err ->
          err
      end
    end
  end

  defp resolve_default_todo_list(ctx) do
    opts = [
      url:    "#{@graph_base}/todo/lists",
      params: [{"$filter", "displayName eq 'Tasks'"}, {"$top", 1}]
    ]

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => [%{"id" => id} | _]}} -> {:ok, id}
      {:ok, 200, %{"value" => []}} ->
        # Locale variants — fall back to the first list returned
        # without a filter. Better than failing the call.
        opts_any = [url: "#{@graph_base}/todo/lists", params: [{"$top", 1}]]

        case RestBridge.raw_request(:get, with_bearer(opts_any, ctx)) do
          {:ok, 200, %{"value" => [%{"id" => id} | _]}} -> {:ok, id}
          _ -> {:error, :not_found}
        end

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_todo_task(%{} = item) do
    %{
      "id"     => item["id"],
      "title"  => item["title"],
      "notes"  => get_in(item, ["body", "content"]),
      "due"    => get_in(item, ["dueDateTime", "dateTime"]),
      "status" => item["status"]
    }
  end

  defp build_todo_body(nil), do: nil
  defp build_todo_body(""),  do: nil
  defp build_todo_body(text), do: %{"content" => text, "contentType" => "text"}

  defp build_todo_due(nil), do: nil
  defp build_todo_due(""),  do: nil
  defp build_todo_due(iso), do: %{"dateTime" => iso, "timeZone" => "UTC"}

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)

  # ─── contacts.search — $search KQL ────────────────────────────────────

  defp contacts_search(args, ctx) do
    q     = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 10)

    opts = [
      url:     "#{@graph_base}/contacts",
      params:  [{"$search", "\"#{q}\""}, {"$top", limit},
                {"$select", "id,displayName,emailAddresses"}],
      headers: [{"consistencylevel", "eventual"}]
    ]

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => contacts}} when is_list(contacts) ->
        flat =
          Enum.map(contacts, fn c ->
            %{
              "name"  => c["displayName"],
              "email" => get_in(c, ["emailAddresses", Access.at(0), "address"])
            }
          end)

        {:ok, %{"contacts" => flat}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── excel.read_range — workbook /worksheets/{sheet}/range ────────────

  defp excel_read_range(args, ctx) do
    workbook_id = args["workbook_id"]
    sheet       = args["worksheet"]
    range       = args["range"]

    url =
      "#{@graph_base}/drive/items/#{URI.encode(workbook_id)}" <>
        "/workbook/worksheets/#{URI.encode(sheet)}/range(address='#{URI.encode(range)}')"

    case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
      {:ok, 200, body} ->
        {:ok, %{
          "workbook_id" => workbook_id,
          "worksheet"   => sheet,
          "range"       => body["address"] || range,
          "values"      => Map.get(body, "values", [])
        }}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

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

  defp user_email_from_ctx(_ctx), do: nil

  # ─── mail.reply — POST /me/messages/{id}/reply ────────────────────────

  defp mail_reply(args, ctx) do
    message_id = args["message_id"]
    body_text  = args["body"] || ""

    url = "#{@graph_base}/messages/#{URI.encode(message_id)}/reply"

    body = %{
      "comment" => body_text
    }

    case RestBridge.raw_request(:post, with_bearer([url: url, json: body], ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{"ok" => true, "message_id" => message_id}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── cal.update_event — PATCH /me/events/{id} ─────────────────────────

  defp cal_update_event(args, ctx) do
    event_id = args["event_id"]
    patch    = Map.get(args, "patch") || %{}

    url = "#{@graph_base}/events/#{URI.encode(event_id)}"

    case RestBridge.raw_request(:patch, with_bearer([url: url, json: patch], ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{"event_id" => body["id"], "updated" => Map.keys(patch)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── onenote.read_page — GET /me/onenote/pages/{id}/content ───────────
  # Graph returns text/html; we strip HTML tags for the agent (the
  # full HTML is rarely useful and inflates the model's context).

  defp onenote_read_page(args, ctx) do
    page_id = args["page_id"]
    url = "#{@graph_base}/onenote/pages/#{URI.encode(page_id)}/content"

    case RestBridge.raw_request(:get, with_bearer([url: url, accept: "text/html"], ctx)) do
      {:ok, status, html} when status in 200..299 and is_binary(html) ->
        text = strip_html_to_text(html)
        {:ok, %{"text" => text, "title" => "OneNote page"}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp strip_html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
  defp strip_html_to_text(_), do: ""
end
