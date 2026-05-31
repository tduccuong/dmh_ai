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
  @graph_root "https://graph.microsoft.com/v1.0"

  # Microsoft Graph identifiers used in URL path segments:
  #   * mailbox message ids — base64url, may include `=`/`-`/`_`
  #   * drive item ids       — base64url
  #   * To Do list / task ids — base64url
  #   * Teams channel ids    — `19:<base64>@thread.tacv2` (colons + `@`)
  # The whitelist accepts every shape Graph actually returns; anything
  # else raises, so the dispatcher surfaces an error envelope rather
  # than constructing a URL with an injected path segment.
  @path_id_re ~r/^[A-Za-z0-9_=:@.\-]+$/

  # Excel range in A1 notation (single cell or range, e.g. `A1`, `B2:D10`).
  @excel_range_re ~r/^[A-Z]+\d+(:[A-Z]+\d+)?$/

  # Outlook well-known mail folder ids accepted in addition to mailbox
  # folder ids. The whitelist regex already covers them, but they're
  # listed here so future readers know which strings the model is
  # expected to pass for the common destinations:
  #   inbox · archive · deleteditems · drafts · sentitems · junkemail

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
      },
      "cal.list_events" => %FunctionSpec{
        handler: &cal_list_events/2,
        doc:     "List Outlook calendar events between two timestamps (optionally KQL-filtered)."
      },
      "mail.read" => %FunctionSpec{
        handler: &mail_read/2,
        doc:     "Fetch a single Outlook message with full body + attachments metadata."
      },
      "mail.move_to_folder" => %FunctionSpec{
        handler: &mail_move_to_folder/2,
        doc:     "Move an Outlook message to a destination folder (well-known id or mailbox folder id)."
      },
      "excel.update_range" => %FunctionSpec{
        handler: &excel_update_range/2,
        doc:     "Write a 2D values array into an Excel worksheet range (A1 notation)."
      },
      "files.download" => %FunctionSpec{
        handler: &files_download/2,
        doc:     "Download a OneDrive item's content (text passes through, binary base64-encoded)."
      },
      "teams.list_channels" => %FunctionSpec{
        handler: &teams_list_channels/2,
        doc:     "List channels of a Microsoft Teams team."
      },
      "teams.post_channel_message" => %FunctionSpec{
        handler: &teams_post_channel_message/2,
        doc:     "Post a message into a Teams channel (HTML body)."
      },
      "todo.complete" => %FunctionSpec{
        handler: &todo_complete/2,
        doc:     "Mark a Microsoft To Do task as completed."
      },
      "user.find_by_email" => %FunctionSpec{
        handler: &user_find_by_email/2,
        doc:     "Look up a directory user by email (Graph GET /users/{email}). Identity pivot."
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

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
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

  # ─── mail.read — GET /me/messages/{id} ────────────────────────────────
  # vendor: GET /v1.0/me/messages/{id}?$expand=attachments($select=…)
  # docs:   https://learn.microsoft.com/graph/api/message-get
  # Returns the message body + attachments metadata so the model can
  # reference attachment names + sizes without downloading them.

  defp mail_read(args, ctx) do
    message_id = safe_path_id(args["message_id"])
    url        = "#{@graph_base}/messages/#{message_id}"

    opts = [
      url:    url,
      params: [
        {"$expand", "attachments($select=id,name,contentType,size)"},
        {"$select", "id,subject,from,toRecipients,receivedDateTime,body,bodyPreview,hasAttachments"}
      ]
    ]

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"message" => normalise_message(body)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_message(m) do
    %{
      "id"             => m["id"],
      "subject"        => m["subject"],
      "from"           => get_in(m, ["from", "emailAddress", "address"]),
      "to"             => Enum.map(m["toRecipients"] || [],
                            fn r -> get_in(r, ["emailAddress", "address"]) end),
      "received_at"    => m["receivedDateTime"],
      "body"           => get_in(m, ["body", "content"]),
      "body_type"      => get_in(m, ["body", "contentType"]),
      "snippet"        => m["bodyPreview"],
      "has_attachments" => m["hasAttachments"],
      "attachments"    => Enum.map(m["attachments"] || [], &normalise_attachment/1)
    }
  end

  defp normalise_attachment(a) do
    %{
      "id"           => a["id"],
      "name"         => a["name"],
      "content_type" => a["contentType"],
      "size"         => a["size"]
    }
  end

  # ─── mail.move_to_folder — POST /me/messages/{id}/move ────────────────
  # vendor: POST /v1.0/me/messages/{id}/move  body: {"destinationId":"<id>"}
  # docs:   https://learn.microsoft.com/graph/api/message-move
  # Graph returns the moved message — we only need the new id.

  defp mail_move_to_folder(args, ctx) do
    message_id     = safe_path_id(args["message_id"])
    destination_id = safe_path_id(args["destination_folder_id"])

    url  = "#{@graph_base}/messages/#{message_id}/move"
    body = %{"destinationId" => destination_id}

    case RestBridge.raw_request(:post, with_bearer([url: url, json: body], ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"message_id" => body["id"] || message_id}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── excel.update_range — PATCH workbook range ────────────────────────
  # vendor: PATCH /v1.0/me/drive/items/{id}/workbook/worksheets/{sheet}/range(address='A1:C5')
  # docs:   https://learn.microsoft.com/graph/api/range-update
  # `range` is validated against A1 notation before the URL is built.

  defp excel_update_range(args, ctx) do
    file_id   = safe_path_id(args["file_id"])
    worksheet = safe_path_id(args["worksheet"])
    range     = validate_excel_range(args["range"])
    values    = args["values"]

    url =
      "#{@graph_base}/drive/items/#{file_id}" <>
        "/workbook/worksheets/#{worksheet}/range(address='#{range}')"

    case RestBridge.raw_request(:patch, with_bearer([url: url, json: %{"values" => values}], ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{"ok" => true}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp validate_excel_range(range) do
    str = to_string(range)

    if Regex.match?(@excel_range_re, str) do
      str
    else
      raise ArgumentError, "invalid Excel range (A1 notation expected): #{inspect(range)}"
    end
  end

  # ─── files.download — GET /me/drive/items/{id}/content ────────────────
  # vendor: GET /v1.0/me/drive/items/{id}/content
  # docs:   https://learn.microsoft.com/graph/api/driveitem-get-content
  # text/* content passes through as a string; binary content is
  # base64-encoded so the model can still reference / forward it
  # through a string envelope. Larger-than-context files are an
  # operator concern (no automatic chunking here).

  defp files_download(args, ctx) do
    file_id = safe_path_id(args["file_id"])
    url     = "#{@graph_base}/drive/items/#{file_id}/content"

    case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {content, mime} = encode_download_body(body)
        {:ok, %{"content" => content, "content_type" => mime}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp encode_download_body(body) when is_binary(body) do
    if String.valid?(body) and printable?(body) do
      {body, "text/plain"}
    else
      {Base.encode64(body), "application/octet-stream"}
    end
  end

  defp encode_download_body(body) when is_map(body) do
    # Graph occasionally returns JSON metadata when a follow-up
    # download link is required; surface it verbatim so the agent
    # can decide what to do next.
    {Jason.encode!(body), "application/json"}
  end

  defp encode_download_body(other), do: {to_string(other), "text/plain"}

  defp printable?(s),
    do: String.printable?(s) or String.printable?(s, 0)

  # ─── teams.list_channels — GET /teams/{id}/channels ───────────────────
  # vendor: GET /v1.0/teams/{team_id}/channels?$top=N
  # docs:   https://learn.microsoft.com/graph/api/channel-list

  defp teams_list_channels(args, ctx) do
    team_id = safe_path_id(args["team_id"])
    limit   = Map.get(args, "limit", 25)

    opts = [
      url:    "#{@graph_root}/teams/#{team_id}/channels",
      params: [{"$top", limit}, {"$select", "id,displayName,description,membershipType"}]
    ]

    case RestBridge.raw_request(:get, with_bearer(opts, ctx)) do
      {:ok, 200, %{"value" => channels}} when is_list(channels) ->
        flat = Enum.map(channels, &normalise_channel/1)
        {:ok, %{"channels" => flat}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  defp normalise_channel(c) do
    %{
      "id"              => c["id"],
      "name"            => c["displayName"],
      "description"     => c["description"],
      "membership_type" => c["membershipType"]
    }
  end

  # ─── teams.post_channel_message — POST channel message ────────────────
  # vendor: POST /v1.0/teams/{team_id}/channels/{channel_id}/messages
  # docs:   https://learn.microsoft.com/graph/api/chatmessage-post
  # Channel ids look like `19:<base64>@thread.tacv2`, hence the
  # `:`/`@` in the whitelist; team ids are plain UUIDs.

  defp teams_post_channel_message(args, ctx) do
    team_id    = safe_path_id(args["team_id"])
    channel_id = safe_path_id(args["channel_id"])
    body_text  = args["body"] || ""
    subject    = Map.get(args, "subject")

    url = "#{@graph_root}/teams/#{team_id}/channels/#{channel_id}/messages"

    body =
      %{
        "body" => %{"contentType" => "html", "content" => body_text}
      }
      |> maybe_put_kv("subject", subject)

    case RestBridge.raw_request(:post, with_bearer([url: url, json: body], ctx)) do
      {:ok, status, resp} when status in 200..299 and is_map(resp) ->
        {:ok, %{"message_id" => to_string(resp["id"] || "")}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── todo.complete — PATCH /me/todo/lists/{list}/tasks/{task} ─────────
  # vendor: PATCH /v1.0/me/todo/lists/{list_id}/tasks/{task_id}
  #         body: {"status":"completed"}
  # docs:   https://learn.microsoft.com/graph/api/todotask-update
  # Graph sets `completedDateTime` itself when status flips.

  defp todo_complete(args, ctx) do
    list_id = safe_path_id(args["list_id"])
    task_id = safe_path_id(args["task_id"])

    url  = "#{@graph_base}/todo/lists/#{list_id}/tasks/#{task_id}"
    body = %{"status" => "completed"}

    case RestBridge.raw_request(:patch, with_bearer([url: url, json: body], ctx)) do
      {:ok, status, resp} when status in 200..299 and is_map(resp) ->
        {:ok, %{"task_id" => to_string(resp["id"] || task_id)}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── user.find_by_email — GET /users/{email} ─────────────────────────
  # vendor: GET /v1.0/users/{email}
  # docs:   https://learn.microsoft.com/graph/api/user-get
  # Graph accepts the userPrincipalName (= email for most tenants)
  # directly as the path id. The whole user resource is surfaced as
  # `%{"user" => body}` so downstream `{{N.user.id}}` references
  # pick up the Graph user object id.

  defp user_find_by_email(args, ctx) do
    email = safe_path_id(args["email"])
    url   = "#{@graph_root}/users/#{email}"

    case RestBridge.raw_request(:get, with_bearer([url: url], ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, %{"user" => body}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── path id guard ────────────────────────────────────────────────────
  # Graph identifiers used in URL segments are validated against
  # `@path_id_re` (see top of module). A value that doesn't match
  # raises — the dispatcher surfaces it as an error envelope rather
  # than building a URL with an injected path segment.

  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid m365 path id: #{inspect(id)}"
    end
  end
end
