# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.HubSpot.MCPHandler do
  @moduledoc """
  FunctionSpec map for the HubSpot connector consumed by the
  generic `Connectors.MCPServer`. Each function is a 1:1 mapping
  to a HubSpot CRM v3 endpoint at `api.hubapi.com/crm/v3/*`:

    contact.find   — POST  /crm/v3/objects/contacts/search
    contact.create — POST  /crm/v3/objects/contacts
    contact.update — PATCH /crm/v3/objects/contacts/{id}
    company.find   — POST  /crm/v3/objects/companies/search
    company.create — POST  /crm/v3/objects/companies
    company.update — PATCH /crm/v3/objects/companies/{id}
    deal.find      — POST  /crm/v3/objects/deals/search
    deal.create    — POST  /crm/v3/objects/deals
    deal.update    — PATCH /crm/v3/objects/deals/{id}
    activity.log   — POST  /crm/v3/objects/notes
    task.create    — POST  /crm/v3/objects/tasks

  HubSpot's search API is POST-with-body (filterGroups + query),
  not the GET-with-$search style Microsoft Graph uses. The shim
  builds the request body inline; the response carries `results`
  with `properties` payload — we flatten to the canonical
  `{id, name, email, …}` shape so the model treats every CRM the
  same regardless of vendor.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  require Logger

  @api_base "https://api.hubapi.com/crm/v3/objects"

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "hubspot", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "contact.find" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/contacts/search",
        request: &contact_find_request/2,
        response: &contact_find_response/2,
        doc:     "Search HubSpot contacts; returns name + email + id."
      },
      "contact.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/contacts",
        request: &contact_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"contact_id" => body["id"], "email" => get_in(body, ["properties", "email"])}}
                  end,
        doc:     "Create or upsert a contact by email."
      },
      "deal.find" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/deals/search",
        request: &deal_find_request/2,
        response: &deal_find_response/2,
        doc:     "Search HubSpot deals; filter by stage / owner."
      },
      "deal.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/deals",
        request: &deal_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"deal_id" => body["id"], "name" => get_in(body, ["properties", "dealname"])}}
                  end,
        doc:     "Create a deal linked to a contact."
      },
      "deal.update" => %FunctionSpec{
        handler: &deal_update/2,
        doc:     "Patch deal properties (stage transitions, amount changes, …)."
      },
      "contact.update" => %FunctionSpec{
        handler: &contact_update/2,
        doc:     "Patch contact properties (title, company, phone, …)."
      },
      "company.find" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/companies/search",
        request: &company_find_request/2,
        response: &company_find_response/2,
        doc:     "Search HubSpot companies; returns name + domain + id."
      },
      "company.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/companies",
        request: &company_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"company_id" => body["id"], "name" => get_in(body, ["properties", "name"])}}
                  end,
        doc:     "Create a company record."
      },
      "company.update" => %FunctionSpec{
        handler: &company_update/2,
        doc:     "Patch company properties (industry, employees, …)."
      },
      "activity.log" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/notes",
        request: &activity_log_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"activity_id" => body["id"]}}
                  end,
        doc:     "Log a Note engagement on a deal."
      },
      "task.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/tasks",
        request: &task_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"task_id" => body["id"]}}
                  end,
        doc:     "Create a Task engagement — actionable follow-up tied to a deal or contact."
      }
    }
  end

  # ─── contact.find — POST search ───────────────────────────────────────

  defp contact_find_request(args, _ctx) do
    q     = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 10)

    [
      json: %{
        "query"      => q,
        "limit"      => limit,
        "properties" => ["email", "firstname", "lastname", "company"]
      }
    ]
  end

  defp contact_find_response(s, body) when s in 200..299 do
    contacts =
      Map.get(body, "results", [])
      |> Enum.map(&normalise_contact/1)

    {:ok, %{"contacts" => contacts}}
  end

  defp normalise_contact(c) do
    props = Map.get(c, "properties", %{})
    name = [props["firstname"], props["lastname"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> String.trim()

    %{
      "id"      => c["id"],
      "name"    => if(name == "", do: nil, else: name),
      "email"   => props["email"],
      "company" => props["company"]
    }
  end

  # ─── contact.create — POST create ─────────────────────────────────────

  defp contact_create_request(args, _ctx) do
    props =
      %{"email" => args["email"]}
      |> maybe_put_kv("firstname", Map.get(args, "first_name"))
      |> maybe_put_kv("lastname",  Map.get(args, "last_name"))
      |> maybe_put_kv("company",   Map.get(args, "company"))

    [json: %{"properties" => props}]
  end

  # ─── deal.find — POST search ──────────────────────────────────────────

  defp deal_find_request(args, _ctx) do
    filters = []

    filters =
      case Map.get(args, "stage") do
        s when is_binary(s) and s != "" ->
          filters ++ [%{"propertyName" => "dealstage", "operator" => "EQ", "value" => s}]
        _ -> filters
      end

    filters =
      case Map.get(args, "owner") do
        o when is_binary(o) and o != "" ->
          filters ++ [%{"propertyName" => "hubspot_owner_id", "operator" => "EQ", "value" => o}]
        _ -> filters
      end

    body =
      %{
        "limit"      => Map.get(args, "limit", 10),
        "properties" => ["dealname", "amount", "dealstage", "closedate", "hubspot_owner_id"]
      }

    body =
      case filters do
        []   -> body
        list -> Map.put(body, "filterGroups", [%{"filters" => list}])
      end

    [json: body]
  end

  defp deal_find_response(s, body) when s in 200..299 do
    deals =
      Map.get(body, "results", [])
      |> Enum.map(&normalise_deal/1)

    {:ok, %{"deals" => deals}}
  end

  defp normalise_deal(d) do
    props = Map.get(d, "properties", %{})

    %{
      "id"          => d["id"],
      "name"        => props["dealname"],
      "amount"      => props["amount"],
      "stage"       => props["dealstage"],
      "close_date"  => props["closedate"],
      "owner_id"    => props["hubspot_owner_id"]
    }
  end

  # ─── deal.create — POST create + association ──────────────────────────

  defp deal_create_request(args, _ctx) do
    props =
      %{"amount" => to_string(args["amount"])}
      |> maybe_put_kv("dealstage", Map.get(args, "stage"))
      |> maybe_put_kv("dealname",  Map.get(args, "name"))

    # HubSpot's "associate on create" shape: `associations` with
    # a `to: { id }` + `types: [{associationCategory, typeId}]`.
    # typeId 3 = contact-to-deal in the standard association
    # type registry (see HubSpot's association-types docs).
    associations =
      case args["contact_id"] do
        cid when is_binary(cid) and cid != "" ->
          [%{
            "to" => %{"id" => cid},
            "types" => [
              %{"associationCategory" => "HUBSPOT_DEFINED", "associationTypeId" => 3}
            ]
          }]

        _ ->
          []
      end

    [json: %{"properties" => props, "associations" => associations}]
  end

  # ─── deal.update — PATCH with dynamic URL ─────────────────────────────

  defp deal_update(args, ctx) do
    patch_object(:deals, args["deal_id"], "deal_id", args["patch"], ctx)
  end

  defp contact_update(args, ctx) do
    patch_object(:contacts, args["contact_id"], "contact_id", args["patch"], ctx)
  end

  defp company_update(args, ctx) do
    patch_object(:companies, args["company_id"], "company_id", args["patch"], ctx)
  end

  defp patch_object(object_plural, id, result_key, patch, ctx) do
    patch = patch || %{}
    url   = "#{@api_base}/#{object_plural}/#{URI.encode(id)}"
    opts  = [url: url, json: %{"properties" => patch}]

    case RestBridge.raw_request(:patch, with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        {:ok, %{result_key => body["id"], "updated" => Map.keys(patch)}}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── company.find — POST search ───────────────────────────────────────

  defp company_find_request(args, _ctx) do
    [
      json: %{
        "query"      => Map.get(args, "query", ""),
        "limit"      => Map.get(args, "limit", 10),
        "properties" => ["name", "domain", "city", "country", "industry"]
      }
    ]
  end

  defp company_find_response(s, body) when s in 200..299 do
    companies =
      Map.get(body, "results", [])
      |> Enum.map(fn c ->
        props = Map.get(c, "properties", %{})
        %{
          "id"       => c["id"],
          "name"     => props["name"],
          "domain"   => props["domain"],
          "city"     => props["city"],
          "country"  => props["country"],
          "industry" => props["industry"]
        }
      end)

    {:ok, %{"companies" => companies}}
  end

  # ─── company.create ───────────────────────────────────────────────────

  defp company_create_request(args, _ctx) do
    props =
      %{"name" => args["name"]}
      |> maybe_put_kv("domain",  Map.get(args, "domain"))
      |> maybe_put_kv("city",    Map.get(args, "city"))
      |> maybe_put_kv("country", Map.get(args, "country"))

    [json: %{"properties" => props}]
  end

  # ─── activity.log — Note engagement linked to deal ────────────────────

  defp activity_log_request(args, _ctx) do
    now_ms = :os.system_time(:millisecond)

    props = %{
      "hs_note_body"       => args["body"],
      "hs_timestamp"       => to_string(now_ms)
    }

    # Notes can carry a `kind` hint via custom property, but
    # HubSpot doesn't have a first-class "activity kind" on Notes.
    # We round-trip it via `hs_note_body` prefix when set.
    props =
      case args["kind"] do
        k when is_binary(k) and k != "" ->
          Map.put(props, "hs_note_body", "[#{k}] " <> args["body"])
        _ -> props
      end

    # typeId 214 = note-to-deal in HubSpot's standard association
    # type registry.
    associations = [
      %{
        "to" => %{"id" => args["deal_id"]},
        "types" => [
          %{"associationCategory" => "HUBSPOT_DEFINED", "associationTypeId" => 214}
        ]
      }
    ]

    [json: %{"properties" => props, "associations" => associations}]
  end

  # ─── task.create — Task engagement ────────────────────────────────────

  defp task_create_request(args, _ctx) do
    now_ms = :os.system_time(:millisecond)

    props =
      %{
        "hs_task_subject"  => args["subject"],
        "hs_task_status"   => "NOT_STARTED",
        "hs_timestamp"     => to_string(now_ms)
      }
      |> maybe_put_kv("hs_task_body",     Map.get(args, "body"))
      |> maybe_put_kv("hs_task_priority", normalise_priority(Map.get(args, "priority")))
      |> maybe_put_kv("hs_task_type",     normalise_task_type(Map.get(args, "task_type")))
      |> maybe_put_kv("hs_timestamp",     normalise_due_date(Map.get(args, "due_date")) || to_string(now_ms))

    # Associate task with deal (typeId 216 = task-to-deal) and/or
    # contact (typeId 204 = task-to-contact). HubSpot's standard
    # association type registry.
    associations =
      []
      |> maybe_append_assoc(Map.get(args, "deal_id"),    216)
      |> maybe_append_assoc(Map.get(args, "contact_id"), 204)

    [json: %{"properties" => props, "associations" => associations}]
  end

  defp normalise_priority(nil), do: nil
  defp normalise_priority(p) when is_binary(p) do
    case String.upcase(p) do
      v when v in ["HIGH", "MEDIUM", "LOW", "NONE"] -> v
      _ -> "MEDIUM"
    end
  end

  defp normalise_task_type(nil), do: nil
  defp normalise_task_type(t) when is_binary(t) do
    case String.upcase(t) do
      v when v in ["CALL", "EMAIL", "TODO"] -> v
      _ -> "TODO"
    end
  end

  # HubSpot's `hs_timestamp` is ms since epoch. Accept ISO 8601
  # strings from the agent and convert; pass through ms strings.
  defp normalise_due_date(nil), do: nil
  defp normalise_due_date(""),  do: nil
  defp normalise_due_date(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> to_string(n)
      _ ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _} -> dt |> DateTime.to_unix(:millisecond) |> to_string()
          _ -> nil
        end
    end
  end

  defp maybe_append_assoc(list, nil, _type_id), do: list
  defp maybe_append_assoc(list, "",  _type_id), do: list
  defp maybe_append_assoc(list, id, type_id) do
    list ++
      [%{
        "to" => %{"id" => id},
        "types" => [
          %{"associationCategory" => "HUBSPOT_DEFINED", "associationTypeId" => type_id}
        ]
      }]
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  defp with_bearer(opts, %{bearer_token: t}) when is_binary(t) and t != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"authorization", "Bearer " <> t} | headers])
  end
  defp with_bearer(opts, _), do: opts

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
