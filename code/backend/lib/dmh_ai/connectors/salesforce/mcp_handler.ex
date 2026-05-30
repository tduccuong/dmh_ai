# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Salesforce.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Salesforce connector consumed by the
  generic `Connectors.MCPServer`. Each function is a 1:1 mapping to a
  Salesforce REST endpoint at `{instance}.salesforce.com/services/
  data/v60.0/*`:

    lead.find            — GET   /query?q=<SOQL over Lead>
    lead.create          — POST  /sobjects/Lead
    lead.update          — PATCH /sobjects/Lead/{id}
    contact.find         — GET   /query?q=<SOQL over Contact>
    contact.create       — POST  /sobjects/Contact
    account.find         — GET   /query?q=<SOQL over Account>
    account.create       — POST  /sobjects/Account
    opportunity.find     — GET   /query?q=<SOQL over Opportunity>
    opportunity.create   — POST  /sobjects/Opportunity
    opportunity.update   — PATCH /sobjects/Opportunity/{id}
    case.find            — GET   /query?q=<SOQL over Case>
    case.create          — POST  /sobjects/Case
    case.update          — PATCH /sobjects/Case/{id}
    task.find            — GET   /query?q=<SOQL over Task>
    task.create          — POST  /sobjects/Task
    task.update          — PATCH /sobjects/Task/{id}
    owner.find_by_email  — GET   /query?q=SELECT … FROM User WHERE Email = …
    report.run           — GET   /analytics/reports/{report_id}
    note.create          — POST  /sobjects/Note

  Salesforce's read endpoints are a single `/query` resource driven by
  a SOQL string (`?q=SELECT … FROM <Object> …`), not per-object search
  paths. Each `*.find` request builds the SOQL for its sObject. The
  response carries a `records` array which we flatten to a canonical
  per-object shape (`{id, name, …}`) so the model treats every CRM the
  same regardless of vendor.

  Writes POST to `/sobjects/<Type>`; Salesforce answers
  `{"id": ..., "success": true}` which we map to the manifest's
  declared `<object>_id` key. PATCH on a specific sObject returns
  204 No Content — handler echoes the id.

  `{instance}` in `@api_base` is a placeholder — live calls require
  the framework to template the org's `instance_url` before dispatch.
  The mock vendor server answers by function name, not URL, so it is
  exercised without substitution.

  ## Path-param ids

  Functions acting on a specific record interpolate the id into the
  path via a `:url` function `(args -> url)`. Salesforce ids are
  alphanumeric (15- or 18-char) but the whitelist allows
  `[A-Za-z0-9_-]+` for forward-compatibility (`safe_path_id/1`) —
  no raw interpolation of unvalidated input.

  All SOQL string literals built via `soql_quote/1` (escapes backslash
  first, then the single quote) — closes the SOQL-injection vector on
  every `*.find`.

  Salesforce uses standard `Authorization: Bearer <token>` auth, which
  `RestBridge` injects from `ctx.bearer_token` for the FunctionSpec
  path; the custom PATCH handlers add it explicitly via
  `with_bearer/2`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  require Logger

  @api_base "https://{instance}.salesforce.com/services/data/v60.0"

  # Salesforce object ids are 15- or 18-char alphanumeric. Whitelist
  # `[A-Za-z0-9_-]+` for forward-compatibility (custom-portal aliases
  # may include `-` or `_`). Anything else raises — the dispatcher
  # surfaces it as an error envelope rather than building a URL with
  # an injected path segment.
  @path_id_re ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "salesforce", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "lead.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &lead_find_request/2,
        response: &lead_find_response/2,
        doc:     "Search Salesforce Leads via SOQL; returns name + company + id."
      },
      "lead.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Lead",
        request: &lead_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"lead_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Create a Lead."
      },
      "contact.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &contact_find_request/2,
        response: &contact_find_response/2,
        doc:     "Search Salesforce Contacts via SOQL; returns name + email + id."
      },
      "contact.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Contact",
        request: &contact_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"contact_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Create a Contact."
      },
      "account.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &account_find_request/2,
        response: &account_find_response/2,
        doc:     "Search Salesforce Accounts via SOQL; returns name + website + id."
      },
      "account.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Account",
        request: &account_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"account_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Create an Account."
      },
      "opportunity.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &opportunity_find_request/2,
        response: &opportunity_find_response/2,
        doc:     "List Salesforce Opportunities via SOQL; filter by stage / owner."
      },
      "opportunity.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Opportunity",
        request: &opportunity_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"opportunity_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Open an Opportunity."
      },
      "opportunity.update" => %FunctionSpec{
        handler: &opportunity_update/2,
        doc:     "Patch Opportunity fields (stage, amount, close_date, …)."
      },
      "lead.update" => %FunctionSpec{
        handler: &lead_update/2,
        doc:     "Patch Lead fields (Status, Company, Email, …)."
      },
      "case.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &case_find_request/2,
        response: &case_find_response/2,
        doc:     "Search Salesforce Cases via SOQL; filter by status / owner."
      },
      "case.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Case",
        request: &case_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"case_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Open a support Case."
      },
      "case.update" => %FunctionSpec{
        handler: &case_update/2,
        doc:     "Patch Case fields (Status, Priority, OwnerId, …)."
      },
      "task.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &task_find_request/2,
        response: &task_find_response/2,
        doc:     "Search Salesforce Tasks via SOQL; filter by status / owner / related record."
      },
      "task.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Task",
        request: &task_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"task_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Create a Task activity."
      },
      "task.update" => %FunctionSpec{
        handler: &task_update/2,
        doc:     "Patch Task fields (Status, Priority, ActivityDate, …)."
      },
      "owner.find_by_email" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/query",
        request: &owner_find_by_email_request/2,
        response: &owner_find_by_email_response/2,
        doc:     "Resolve a Salesforce User by email — returns the owner record."
      },
      "report.run" => %FunctionSpec{
        method:  :get,
        url:     &report_run_url/1,
        request: fn _args, _ctx -> [] end,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"report" => body}}
                  end,
        doc:     "Execute a saved Salesforce report by id; returns the raw report body."
      },
      "note.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/sobjects/Note",
        request: &note_create_request/2,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{"note_id" => to_string(Map.get(body, "id"))}}
                  end,
        doc:     "Attach a Note to any Salesforce record."
      }
    }
  end

  # ─── lead.find — GET SOQL query ───────────────────────────────────────

  defp lead_find_request(args, _ctx) do
    soql =
      "SELECT Id, FirstName, LastName, Company, Email, Status FROM Lead" <>
        where_clause(Map.get(args, "query")) <>
        limit_clause(Map.get(args, "limit"))

    [params: %{"q" => soql}]
  end

  defp lead_find_response(s, body) when s in 200..299 do
    leads =
      records(body)
      |> Enum.map(&normalise_lead/1)

    {:ok, %{"leads" => leads}}
  end

  defp normalise_lead(r) do
    name = join_name(r["FirstName"], r["LastName"])

    %{
      "id"      => to_string(record_id(r)),
      "name"    => name,
      "company" => r["Company"],
      "email"   => r["Email"],
      "status"  => r["Status"]
    }
  end

  # ─── lead.create — POST sObject ───────────────────────────────────────

  defp lead_create_request(args, _ctx) do
    body =
      %{"LastName" => args["last_name"], "Company" => args["company"]}
      |> maybe_put_kv("FirstName", Map.get(args, "first_name"))
      |> maybe_put_kv("Email",     Map.get(args, "email"))

    [json: body]
  end

  # ─── contact.find — GET SOQL query ────────────────────────────────────

  defp contact_find_request(args, _ctx) do
    soql =
      "SELECT Id, FirstName, LastName, Email, AccountId FROM Contact" <>
        where_clause(Map.get(args, "query")) <>
        limit_clause(Map.get(args, "limit"))

    [params: %{"q" => soql}]
  end

  defp contact_find_response(s, body) when s in 200..299 do
    contacts =
      records(body)
      |> Enum.map(&normalise_contact/1)

    {:ok, %{"contacts" => contacts}}
  end

  defp normalise_contact(r) do
    %{
      "id"         => to_string(record_id(r)),
      "name"       => join_name(r["FirstName"], r["LastName"]),
      "email"      => r["Email"],
      "account_id" => r["AccountId"]
    }
  end

  # ─── contact.create — POST sObject ────────────────────────────────────

  defp contact_create_request(args, _ctx) do
    body =
      %{"LastName" => args["last_name"]}
      |> maybe_put_kv("FirstName", Map.get(args, "first_name"))
      |> maybe_put_kv("Email",     Map.get(args, "email"))
      |> maybe_put_kv("AccountId", Map.get(args, "account_id"))

    [json: body]
  end

  # ─── account.find — GET SOQL query ────────────────────────────────────

  defp account_find_request(args, _ctx) do
    soql =
      "SELECT Id, Name, Website, Industry FROM Account" <>
        where_clause(Map.get(args, "query")) <>
        limit_clause(Map.get(args, "limit"))

    [params: %{"q" => soql}]
  end

  defp account_find_response(s, body) when s in 200..299 do
    accounts =
      records(body)
      |> Enum.map(&normalise_account/1)

    {:ok, %{"accounts" => accounts}}
  end

  defp normalise_account(r) do
    %{
      "id"       => to_string(record_id(r)),
      "name"     => r["Name"],
      "website"  => r["Website"],
      "industry" => r["Industry"]
    }
  end

  # ─── account.create — POST sObject ────────────────────────────────────

  defp account_create_request(args, _ctx) do
    body =
      %{"Name" => args["name"]}
      |> maybe_put_kv("Website",  Map.get(args, "website"))
      |> maybe_put_kv("Industry", Map.get(args, "industry"))

    [json: body]
  end

  # ─── opportunity.find — GET SOQL query ────────────────────────────────

  defp opportunity_find_request(args, _ctx) do
    soql =
      "SELECT Id, Name, StageName, Amount, CloseDate, AccountId FROM Opportunity" <>
        opportunity_where(args) <>
        limit_clause(Map.get(args, "limit"))

    [params: %{"q" => soql}]
  end

  # Opportunity filters by StageName + Owner.Name, not a free-text
  # query. Compose a conjunctive WHERE from whichever filters are set.
  defp opportunity_where(args) do
    filters =
      []
      |> maybe_filter("StageName", Map.get(args, "stage"))
      |> maybe_filter("Owner.Name", Map.get(args, "owner"))

    case filters do
      []     -> ""
      clauses -> " WHERE " <> Enum.join(clauses, " AND ")
    end
  end

  defp maybe_filter(acc, _field, nil), do: acc
  defp maybe_filter(acc, _field, ""),  do: acc
  defp maybe_filter(acc, field, value), do: acc ++ ["#{field} = #{soql_quote(value)}"]

  defp opportunity_find_response(s, body) when s in 200..299 do
    opportunities =
      records(body)
      |> Enum.map(&normalise_opportunity/1)

    {:ok, %{"opportunities" => opportunities}}
  end

  defp normalise_opportunity(r) do
    %{
      "id"         => to_string(record_id(r)),
      "name"       => r["Name"],
      "stage"      => r["StageName"],
      "amount"     => r["Amount"],
      "close_date" => r["CloseDate"],
      "account_id" => r["AccountId"]
    }
  end

  # ─── opportunity.create — POST sObject ────────────────────────────────

  defp opportunity_create_request(args, _ctx) do
    body =
      %{
        "Name"      => args["name"],
        "StageName" => args["stage"],
        "CloseDate" => args["close_date"]
      }
      |> maybe_put_kv("Amount",    Map.get(args, "amount"))
      |> maybe_put_kv("AccountId", Map.get(args, "account_id"))

    [json: body]
  end

  # ─── opportunity.update — PATCH with dynamic URL ──────────────────────

  defp opportunity_update(args, ctx) do
    patch_sobject("Opportunity", args["opportunity_id"], "opportunity_id", args["patch"], ctx)
  end

  # ─── lead.update — PATCH with dynamic URL ─────────────────────────────

  defp lead_update(args, ctx) do
    patch_sobject("Lead", args["lead_id"], "lead_id", args["patch"], ctx)
  end

  # ─── case.find — GET SOQL query ───────────────────────────────────────

  defp case_find_request(args, _ctx) do
    soql =
      "SELECT Id, Subject, Status, Priority, CreatedDate, OwnerId, AccountId FROM Case" <>
        case_where(args) <>
        limit_clause(Map.get(args, "limit"))

    [params: %{"q" => soql}]
  end

  # Case has no `Name` field, so the free-text predicate runs against
  # `Subject`. Optional `status` / `owner` filters AND on top.
  defp case_where(args) do
    filters =
      []
      |> maybe_subject_like(Map.get(args, "query"))
      |> maybe_filter("Status",     Map.get(args, "status"))
      |> maybe_owner_name_like(Map.get(args, "owner"))

    case filters do
      []      -> ""
      clauses -> " WHERE " <> Enum.join(clauses, " AND ")
    end
  end

  defp case_find_response(s, body) when s in 200..299 do
    cases =
      records(body)
      |> Enum.map(&normalise_case/1)

    {:ok, %{"cases" => cases}}
  end

  defp normalise_case(r) do
    %{
      "id"           => to_string(record_id(r)),
      "subject"      => r["Subject"],
      "status"       => r["Status"],
      "priority"     => r["Priority"],
      "created_date" => r["CreatedDate"],
      "owner_id"     => r["OwnerId"],
      "account_id"   => r["AccountId"]
    }
  end

  # ─── case.create — POST sObject ───────────────────────────────────────

  defp case_create_request(args, _ctx) do
    body =
      %{"Subject" => args["subject"]}
      |> maybe_put_kv("Description", Map.get(args, "description"))
      |> maybe_put_kv("Priority",    Map.get(args, "priority"))
      |> maybe_put_kv("ContactId",   Map.get(args, "contact_id"))

    [json: body]
  end

  # ─── case.update — PATCH with dynamic URL ─────────────────────────────

  defp case_update(args, ctx) do
    patch_sobject("Case", args["case_id"], "case_id", args["patch"], ctx)
  end

  # ─── task.find — GET SOQL query ───────────────────────────────────────

  defp task_find_request(args, _ctx) do
    soql =
      "SELECT Id, Subject, Status, Priority, ActivityDate, OwnerId, WhatId FROM Task" <>
        task_where(args) <>
        limit_clause(Map.get(args, "limit"))

    [params: %{"q" => soql}]
  end

  # Task has no free-text `query` arg; filters are explicit fields.
  # `record_id` matches Salesforce Task.WhatId (the polymorphic link
  # to a parent Account / Opportunity / Case).
  defp task_where(args) do
    filters =
      []
      |> maybe_filter("Status",    Map.get(args, "status"))
      |> maybe_owner_name_like(Map.get(args, "owner"))
      |> maybe_filter("WhatId",    Map.get(args, "record_id"))

    case filters do
      []      -> ""
      clauses -> " WHERE " <> Enum.join(clauses, " AND ")
    end
  end

  defp task_find_response(s, body) when s in 200..299 do
    tasks =
      records(body)
      |> Enum.map(&normalise_task/1)

    {:ok, %{"tasks" => tasks}}
  end

  defp normalise_task(r) do
    %{
      "id"            => to_string(record_id(r)),
      "subject"       => r["Subject"],
      "status"        => r["Status"],
      "priority"      => r["Priority"],
      "activity_date" => r["ActivityDate"],
      "owner_id"      => r["OwnerId"],
      "record_id"     => r["WhatId"]
    }
  end

  # ─── task.create — POST sObject ───────────────────────────────────────

  defp task_create_request(args, _ctx) do
    body =
      %{"Subject" => args["subject"]}
      |> maybe_put_kv("ActivityDate", Map.get(args, "due_date"))
      |> maybe_put_kv("Priority",     Map.get(args, "priority"))
      |> maybe_put_kv("WhoId",        Map.get(args, "contact_id"))

    [json: body]
  end

  # ─── task.update — PATCH with dynamic URL ─────────────────────────────

  defp task_update(args, ctx) do
    patch_sobject("Task", args["task_id"], "task_id", args["patch"], ctx)
  end

  # ─── owner.find_by_email — GET SOQL over User sObject ────────────────

  defp owner_find_by_email_request(args, _ctx) do
    email = Map.get(args, "email", "")

    soql =
      "SELECT Id, Name, Email FROM User WHERE Email = #{soql_quote(email)} LIMIT 1"

    [params: %{"q" => soql}]
  end

  defp owner_find_by_email_response(s, body) when s in 200..299 do
    case records(body) |> List.first() do
      %{} = row ->
        {:ok, %{"owner" => %{
                  "Id"    => to_string(record_id(row) || ""),
                  "Name"  => row["Name"],
                  "Email" => row["Email"]
                }}}

      _ ->
        {:ok, %{"owner" => nil}}
    end
  end

  # ─── report.run — GET /analytics/reports/{report_id} ──────────────────

  defp report_run_url(args),
    do: "#{@api_base}/analytics/reports/#{safe_path_id(args["report_id"])}"

  # ─── note.create — POST /sobjects/Note ────────────────────────────────

  defp note_create_request(args, _ctx) do
    body = %{
      "Title"    => args["title"],
      "Body"     => args["body"],
      "ParentId" => args["parent_id"]
    }

    [json: body]
  end

  # ─── shared PATCH helper ──────────────────────────────────────────────

  # Salesforce PATCH on an sObject (`/sobjects/<Type>/<id>`) returns
  # 204 No Content on success — body is empty, so we don't read fields
  # back; we echo the id + the keys that landed in the patch.
  defp patch_sobject(sobject_type, id, result_key, patch, ctx) do
    patch = patch || %{}
    url   = "#{@api_base}/sobjects/#{sobject_type}/#{safe_path_id(id)}"
    opts  = [url: url, json: patch]

    case RestBridge.raw_request(:patch, with_bearer(opts, ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{result_key => to_string(id), "updated" => Map.keys(patch)}}

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

  # Salesforce SOQL responds with `{"records": [...], "totalSize": N}`.
  defp records(body), do: Map.get(body, "records", [])

  # SOQL records carry the row id at "Id"; the mock fixtures use the
  # lowercase canonical "id" — accept either.
  defp record_id(r), do: r["Id"] || r["id"]

  # Build a `WHERE Name LIKE '%<q>%'` clause from a free-text query.
  # Salesforce SOQL has no full-text operator on the REST `/query`
  # path, so the `*.find` functions approximate with a Name LIKE.
  defp where_clause(nil), do: ""
  defp where_clause(""),  do: ""
  defp where_clause(q),   do: " WHERE Name LIKE #{soql_quote("%" <> q <> "%")}"

  defp limit_clause(nil), do: ""
  defp limit_clause(n) when is_integer(n), do: " LIMIT #{n}"
  defp limit_clause(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> " LIMIT #{i}"
      :error -> ""
    end
  end
  defp limit_clause(_), do: ""

  # SOQL string literals are single-quoted. Escape backslash FIRST
  # (otherwise an input backslash would consume the escape we add for a
  # following quote and let it break out of the literal), then escape
  # the single quote. Closes the SOQL-injection vector on `*.find`.
  defp soql_quote(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'" <> escaped <> "'"
  end

  defp join_name(first, last) do
    name = [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> String.trim()
    if name == "", do: nil, else: name
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)

  # `Subject LIKE '%<q>%'` — free-text predicate for sObjects whose
  # canonical search field is `Subject` rather than `Name` (Case,
  # Task). Uses `soql_quote/1` on the full `%…%` literal so the
  # wildcards stay outside the quoted segment.
  defp maybe_subject_like(acc, nil), do: acc
  defp maybe_subject_like(acc, ""),  do: acc
  defp maybe_subject_like(acc, q),
    do: acc ++ ["Subject LIKE #{soql_quote("%" <> q <> "%")}"]

  # `Owner.Name LIKE '%<owner>%'` — partial match on the related
  # User's Name, since the connector's `owner` filter is a person
  # name, not an OwnerId. Same quoting rule as `maybe_subject_like`.
  defp maybe_owner_name_like(acc, nil), do: acc
  defp maybe_owner_name_like(acc, ""),  do: acc
  defp maybe_owner_name_like(acc, owner),
    do: acc ++ ["Owner.Name LIKE #{soql_quote("%" <> owner <> "%")}"]

  # Whitelist a path-param id to Salesforce's id charset (15- or
  # 18-char alphanumeric, with `_-` allowed for custom-portal aliases)
  # before interpolating into a URL path. A value that doesn't match
  # raises — the dispatcher surfaces it as an error envelope rather
  # than building a URL with an injected path segment.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid salesforce id: #{inspect(id)}"
    end
  end
end
