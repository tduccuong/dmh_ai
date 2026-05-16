# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365 do
  @moduledoc """
  Microsoft 365 connector (Universal Region, Case B — Microsoft
  Graph API).

  Six functions at the SME-relevant Graph slice:

    mail.search           [read]   list / search messages
    mail.send             [write]  send a message
    cal.find_free_slots   [read]   availability lookup
    cal.create_event      [write]  create a calendar event
    files.list            [read]   list OneDrive items
    files.upload          [write]  upload an item

  Vendor quirks captured in `remap_error/1`:
    * 429 `RateLimited` with `Retry-After` header → `:rate_limited`.
    * 404 `ItemNotFound` / `Request_ResourceNotFound` → `:not_found`.
    * 401 `InvalidAuthenticationToken` → `:unauthorised`.
  """

  use DmhAi.Connectors.MCPAdapter
  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "microsoft"

  @impl true
  def manifest do
    %Manifest{
      connector: "m365",
      region:    "universal",
      functions: %{
        "mail.search" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string, required: true},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{messages: :list},
          scopes:  ["Mail.Read"]
        },
        "mail.send" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "to"      => %{type: :string, required: true, format: :email},
            "subject" => %{type: :string, required: true},
            "body"    => %{type: :string, required: true}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :rate_limited, :upstream_5xx],
          scopes:  ["Mail.Send"]
        },
        "cal.find_free_slots" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "duration_min" => %{type: :integer, required: true},
            "between_from" => %{type: :string,  required: true},
            "between_to"   => %{type: :string,  required: true},
            "attendees"    => %{type: :list,    required: false}
          },
          returns: %{slots: :list},
          scopes:  ["Calendars.Read"]
        },
        "cal.create_event" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "title"     => %{type: :string, required: true},
            "start"     => %{type: :string, required: true},
            "end"       => %{type: :string, required: true},
            "attendees" => %{type: :list,   required: false}
          },
          returns: %{event_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["Calendars.ReadWrite"]
        },
        "files.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "path" => %{type: :string, required: false}
          },
          returns: %{items: :list},
          scopes:  ["Files.Read.All"]
        },
        "files.upload" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "path"    => %{type: :string, required: true},
            "content" => %{type: :string, required: true}
          },
          returns: %{file_id: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate],
          scopes:  ["Files.ReadWrite.All"]
        }
      }
    }
  end

  @impl true
  # Microsoft Graph wraps errors as
  #   {"error": {"code": "<CamelCase>", "message": "..."}}
  # The set below covers the high-frequency cases an SME hits.
  def remap_error(%{"error" => %{"code" => code}}) do
    case code do
      "RateLimited"                  -> :rate_limited
      "ItemNotFound"                 -> :not_found
      "Request_ResourceNotFound"     -> :not_found
      "InvalidAuthenticationToken"   -> :unauthorised
      "AuthorizationFailed"          -> :unauthorised
      "NameAlreadyExists"            -> :duplicate
      _                              -> :passthrough
    end
  end

  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error(_), do: :passthrough
end
