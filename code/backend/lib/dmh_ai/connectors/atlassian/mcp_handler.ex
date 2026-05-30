# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Atlassian.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Atlassian connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a Jira or
  Confluence Cloud REST endpoint:

    issue.find           — GET    /rest/api/3/search?jql=<server-built JQL>
    issue.create         — POST   /rest/api/3/issue
    issue.update         — PUT    /rest/api/3/issue/{issue_key}
    issue.transition     — POST   /rest/api/3/issue/{issue_key}/transitions
    issue.comment        — POST   /rest/api/3/issue/{issue_key}/comment
    issue.delete         — DELETE /rest/api/3/issue/{issue_key}
    issue.add_attachment — POST   /rest/api/3/issue/{issue_key}/attachments (multipart)
    sprint.find          — GET    /rest/agile/1.0/board/{board_id}/sprint
    issue.move_to_sprint — POST   /rest/agile/1.0/sprint/{sprint_id}/issue
    board.find           — GET    /rest/agile/1.0/board
    project.find         — GET    /rest/api/3/project
    user.find_by_email   — GET    /rest/api/3/user/search?query=<email>
    page.find            — GET    /wiki/rest/api/content?spaceKey=&title=&type=page
    page.create          — POST   /wiki/rest/api/content
    page.update          — PUT    /wiki/rest/api/content/{page_id}
    page.delete          — DELETE /wiki/rest/api/content/{page_id}
    space.find           — GET    /wiki/rest/api/space

  ## Three per-product API bases

  Unlike single-host connectors (Zoom, Slack), Atlassian's Cloud REST
  is split across three per-product paths that share the same `cloudId`:

    @jira_base       https://api.atlassian.com/ex/jira/{cloudid}/rest/api/3
    @jira_agile_base https://api.atlassian.com/ex/jira/{cloudid}/rest/agile/1.0
    @confluence_base https://api.atlassian.com/ex/confluence/{cloudid}/wiki/rest/api

  Boards + sprints live on the SEPARATE `rest/agile/1.0` prefix, not
  `rest/api/3`; the connector keeps them on their own constant so the
  prefix doesn't get accidentally collapsed back into the main Jira
  base. `{cloudid}` is a placeholder — live calls require the
  framework to template the tenant's `cloudId` (resolved from
  `https://api.atlassian.com/oauth/token/accessible-resources` after
  the OAuth exchange) before dispatch. The mock vendor server answers
  by function name, not URL, so it is exercised without substitution.

  Standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## Path-param ids

  Functions acting on a specific issue (`issue.update` /
  `issue.transition` / `issue.comment` / `issue.delete` /
  `issue.add_attachment`), sprint (`sprint.find` /
  `issue.move_to_sprint`), board (`sprint.find`), or page
  (`page.update` / `page.delete`) interpolate the id into the URL
  path via a `:url` function `(args -> url)`. The id is whitelisted
  to `^[A-Za-z0-9_-]+$` before the URL is built (`safe_path_id/1`) —
  no raw interpolation of unvalidated input. Jira issue keys are like
  `PROJ-123`; sprint / board / Confluence ids are numeric strings;
  all fit.

  ## Multipart attachment upload

  `issue.add_attachment` uses a custom handler (`:handler`) rather
  than the default JSON `:request` builder — Atlassian requires
  `multipart/form-data` for the file part plus the magic
  `X-Atlassian-Token: no-check` header that disables XSRF-token
  enforcement on the attachment endpoint. The handler composes both
  via `RestBridge.raw_request/2`.

  ## JQL safety

  `issue.find` builds JQL server-side from structured args
  (`project_key`, `status`, `limit`). The connector never accepts a raw
  `jql` string from the model — that would be a SQL-injection-shaped
  vector for trusting the LLM. `jql_quote/1` escapes backslash FIRST
  (otherwise an input backslash would consume the escape we add for a
  following quote and let it break out of the literal), then escapes
  the single quote — same shape as Salesforce's `soql_quote/1`. The
  Confluence `page.find` filters with Req's `:params` keyword so the
  encoder URL-escapes each value.
  """

  alias DmhAi.Connectors.MCPServer.{FunctionSpec, RestBridge}
  require Logger

  @jira_base       "https://api.atlassian.com/ex/jira/{cloudid}/rest/api/3"
  @jira_agile_base "https://api.atlassian.com/ex/jira/{cloudid}/rest/agile/1.0"
  @confluence_base "https://api.atlassian.com/ex/confluence/{cloudid}/wiki/rest/api"

  # Atlassian issue keys (`PROJ-123`) and Confluence ids (numeric
  # strings) both fit the alphanumeric-plus-`_-` charset. Whitelist
  # the value before interpolating into a URL path so an attacker
  # can't inject path segments or query strings via a lookup arg.
  @path_id_re ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1` at
  boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "atlassian", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "issue.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@jira_base}/search",
        request: &issue_find_request/2,
        response: &issue_find_response/2,
        doc:     "Search Jira issues via server-built JQL; returns id + key + summary + status."
      },
      "issue.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@jira_base}/issue",
        request: &issue_create_request/2,
        response: &issue_create_response/2,
        doc:     "Create a Jira issue."
      },
      "issue.update" => %FunctionSpec{
        method:  :put,
        url:     &issue_update_url/1,
        request: &issue_update_request/2,
        response: &issue_update_response/2,
        doc:     "PUT fields on an existing Jira issue."
      },
      "issue.transition" => %FunctionSpec{
        method:  :post,
        url:     &issue_transition_url/1,
        request: &issue_transition_request/2,
        response: &issue_transition_response/2,
        doc:     "Transition a Jira issue to another workflow status."
      },
      "issue.comment" => %FunctionSpec{
        method:  :post,
        url:     &issue_comment_url/1,
        request: &issue_comment_request/2,
        response: &issue_comment_response/2,
        doc:     "Add a comment to a Jira issue."
      },
      "issue.delete" => %FunctionSpec{
        method:  :delete,
        url:     &issue_delete_url/1,
        request: &issue_delete_request/2,
        response: &issue_delete_response/2,
        doc:     "Delete a Jira issue by key."
      },
      "issue.add_attachment" => %FunctionSpec{
        handler: &issue_add_attachment/2,
        doc:     "Attach a file to a Jira issue (multipart/form-data; X-Atlassian-Token: no-check)."
      },
      "sprint.find" => %FunctionSpec{
        method:  :get,
        url:     &sprint_find_url/1,
        request: &sprint_find_request/2,
        response: &sprint_find_response/2,
        doc:     "List sprints on a Jira Agile board (filtered by state)."
      },
      "issue.move_to_sprint" => %FunctionSpec{
        method:  :post,
        url:     &issue_move_to_sprint_url/1,
        request: &issue_move_to_sprint_request/2,
        response: &issue_move_to_sprint_response/2,
        doc:     "Move a list of issue keys onto a Jira Agile sprint."
      },
      "board.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@jira_agile_base}/board",
        request: &board_find_request/2,
        response: &board_find_response/2,
        doc:     "List Jira Agile boards."
      },
      "project.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@jira_base}/project",
        request: &project_find_request/2,
        response: &project_find_response/2,
        doc:     "List Jira projects."
      },
      "user.find_by_email" => %FunctionSpec{
        method:  :get,
        url:     "#{@jira_base}/user/search",
        request: &user_find_by_email_request/2,
        response: &user_find_by_email_response/2,
        doc:     "Find the first Jira user matching the supplied email (identity pivot)."
      },
      "page.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@confluence_base}/content",
        request: &page_find_request/2,
        response: &page_find_response/2,
        doc:     "Find Confluence pages by space + optional title."
      },
      "page.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@confluence_base}/content",
        request: &page_create_request/2,
        response: &page_create_response/2,
        doc:     "Create a Confluence page."
      },
      "page.update" => %FunctionSpec{
        method:  :put,
        url:     &page_update_url/1,
        request: &page_update_request/2,
        response: &page_update_response/2,
        doc:     "Replace a Confluence page (title / body / version_number)."
      },
      "page.delete" => %FunctionSpec{
        method:  :delete,
        url:     &page_delete_url/1,
        request: &page_delete_request/2,
        response: &page_delete_response/2,
        doc:     "Delete a Confluence page by id."
      },
      "space.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@confluence_base}/space",
        request: &space_find_request/2,
        response: &space_find_response/2,
        doc:     "List Confluence spaces."
      }
    }
  end

  # ─── issue.find — GET JQL search ──────────────────────────────────────

  defp issue_find_request(args, _ctx) do
    jql =
      "project = #{jql_quote(args["project_key"])}" <>
        status_clause(Map.get(args, "status"))

    params =
      %{"jql" => jql}
      |> maybe_put_kv("maxResults", Map.get(args, "limit"))

    [params: params]
  end

  defp issue_find_response(s, body) when s in 200..299 do
    issues =
      body
      |> Map.get("issues", [])
      |> Enum.map(&normalise_issue/1)

    {:ok, %{"issues" => issues}}
  end

  defp normalise_issue(i) do
    fields = Map.get(i, "fields", %{})

    %{
      "id"      => to_string(Map.get(i, "id") || ""),
      "key"     => Map.get(i, "key"),
      "summary" => Map.get(fields, "summary"),
      "status"  => fields |> Map.get("status", %{}) |> Map.get("name")
    }
  end

  # ─── issue.create — POST /issue ───────────────────────────────────────

  defp issue_create_request(args, _ctx) do
    fields =
      %{
        "project"   => %{"key"  => args["project_key"]},
        "summary"   => args["summary"],
        "issuetype" => %{"name" => args["issue_type"]}
      }
      |> maybe_put_kv("description", Map.get(args, "description"))

    [json: %{"fields" => fields}]
  end

  defp issue_create_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "issue_id" => to_string(Map.get(body, "id") || ""),
       "key"      => Map.get(body, "key")
     }}
  end

  # ─── issue.update — PUT /issue/{key} ─────────────────────────────────

  defp issue_update_url(args),
    do: "#{@jira_base}/issue/#{safe_path_id(args["issue_key"])}"

  defp issue_update_request(args, _ctx) do
    patch = args["patch"] || %{}
    [json: %{"fields" => patch}]
  end

  # Jira PUT on an issue returns 204 No Content on success — echo the
  # id rather than reading fields back from an empty body.
  defp issue_update_response(s, _body) when s in 200..299 do
    {:ok, %{"issue_id" => "updated"}}
  end

  # ─── issue.transition — POST /issue/{key}/transitions ─────────────────

  defp issue_transition_url(args),
    do: "#{@jira_base}/issue/#{safe_path_id(args["issue_key"])}/transitions"

  defp issue_transition_request(args, _ctx) do
    [json: %{"transition" => %{"id" => args["transition_id"]}}]
  end

  defp issue_transition_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── issue.comment — POST /issue/{key}/comment ────────────────────────

  defp issue_comment_url(args),
    do: "#{@jira_base}/issue/#{safe_path_id(args["issue_key"])}/comment"

  defp issue_comment_request(args, _ctx) do
    [json: %{"body" => args["body"]}]
  end

  defp issue_comment_response(s, body) when s in 200..299 do
    {:ok, %{"comment_id" => to_string(Map.get(body, "id") || "")}}
  end

  # ─── issue.delete — DELETE /issue/{key} ───────────────────────────────

  defp issue_delete_url(args),
    do: "#{@jira_base}/issue/#{safe_path_id(args["issue_key"])}"

  # No body / no params on a Jira issue DELETE — return an empty opts
  # list so the default `:params` builder doesn't get triggered.
  defp issue_delete_request(_args, _ctx), do: []

  # Jira DELETE returns 204 No Content on success — surface a boolean.
  defp issue_delete_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── issue.add_attachment — POST /issue/{key}/attachments (multipart) ──

  # Custom handler: Atlassian requires `multipart/form-data` for the
  # file part PLUS the magic `X-Atlassian-Token: no-check` header that
  # disables XSRF-token enforcement on the attachment endpoint. The
  # default JSON `:request` builder fits neither, so the handler owns
  # the full HTTP call via `RestBridge.raw_request/2`.
  defp issue_add_attachment(args, ctx) do
    boundary =
      "----dmh-ai-atl-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    body =
      build_attachment_multipart(boundary, args["filename"], args["content"])

    headers = [
      {"content-type",       "multipart/form-data; boundary=#{boundary}"},
      {"x-atlassian-token",  "no-check"},
      {"authorization",      "Bearer #{ctx[:bearer_token] || ""}"}
    ]

    url = "#{@jira_base}/issue/#{safe_path_id(args["issue_key"])}/attachments"

    case RestBridge.raw_request(:post, url: url, headers: headers, body: body) do
      {:ok, status, resp_body} when status in 200..299 ->
        {:ok, %{"attachment_id" => attachment_id_from(resp_body)}}

      {:ok, _status, resp_body} ->
        {:error, resp_body}

      {:error, _} = err ->
        err
    end
  end

  # Jira returns the attachment array body — the first element's `id`
  # is the canonical attachment id we hand back to the caller.
  defp attachment_id_from([%{"id" => id} | _]), do: to_string(id)
  defp attachment_id_from(%{"id" => id}),       do: to_string(id)
  defp attachment_id_from(_),                   do: ""

  defp build_attachment_multipart(boundary, filename, content) do
    safe_name = filename |> to_string() |> String.replace("\"", "")

    IO.iodata_to_binary([
      "--", boundary, "\r\n",
      ~s(content-disposition: form-data; name="file"; filename="),
      safe_name, ~s("), "\r\n",
      "content-type: application/octet-stream\r\n\r\n",
      to_string(content), "\r\n",
      "--", boundary, "--", "\r\n"
    ])
  end

  # ─── sprint.find — GET /rest/agile/1.0/board/{board_id}/sprint ────────

  defp sprint_find_url(args),
    do: "#{@jira_agile_base}/board/#{safe_path_id(args["board_id"])}/sprint"

  defp sprint_find_request(args, _ctx) do
    params =
      %{}
      |> maybe_put_kv("state", Map.get(args, "state"))
      |> maybe_put_kv("maxResults", Map.get(args, "limit"))

    [params: params]
  end

  defp sprint_find_response(s, body) when s in 200..299 do
    sprints =
      body
      |> sprints_list()
      |> Enum.map(&normalise_sprint/1)

    {:ok, %{"sprints" => sprints}}
  end

  defp sprints_list(%{"values" => list}) when is_list(list), do: list
  defp sprints_list(_), do: []

  defp normalise_sprint(s) do
    %{
      "id"    => to_string(Map.get(s, "id") || ""),
      "name"  => Map.get(s, "name"),
      "state" => Map.get(s, "state")
    }
  end

  # ─── issue.move_to_sprint — POST /sprint/{sprint_id}/issue ────────────

  defp issue_move_to_sprint_url(args),
    do: "#{@jira_agile_base}/sprint/#{safe_path_id(args["sprint_id"])}/issue"

  defp issue_move_to_sprint_request(args, _ctx) do
    [json: %{"issues" => args["issue_keys"] || []}]
  end

  defp issue_move_to_sprint_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── board.find — GET /rest/agile/1.0/board ───────────────────────────

  defp board_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "maxResults", Map.get(args, "limit"))
    [params: params]
  end

  defp board_find_response(s, body) when s in 200..299 do
    boards =
      body
      |> boards_list()
      |> Enum.map(&normalise_board/1)

    {:ok, %{"boards" => boards}}
  end

  defp boards_list(%{"values" => list}) when is_list(list), do: list
  defp boards_list(_), do: []

  defp normalise_board(b) do
    %{
      "id"   => to_string(Map.get(b, "id") || ""),
      "name" => Map.get(b, "name"),
      "type" => Map.get(b, "type")
    }
  end

  # ─── project.find — GET /project ──────────────────────────────────────

  defp project_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "maxResults", Map.get(args, "limit"))
    [params: params]
  end

  defp project_find_response(s, body) when s in 200..299 do
    projects =
      body
      |> projects_list()
      |> Enum.map(&normalise_project/1)

    {:ok, %{"projects" => projects}}
  end

  # Jira returns the project list either as a bare array (classic) or
  # as `{"values": [...]}` (paginated). Tolerate both.
  defp projects_list(body) when is_list(body), do: body
  defp projects_list(%{"values" => list}) when is_list(list), do: list
  defp projects_list(_), do: []

  defp normalise_project(p) do
    %{
      "id"   => to_string(Map.get(p, "id") || ""),
      "key"  => Map.get(p, "key"),
      "name" => Map.get(p, "name")
    }
  end

  # ─── user.find_by_email — GET /user/search?query=<email> ──────────────

  # Atlassian's user-search endpoint matches by email OR display
  # name via the same `query` param. Take the first record and
  # surface it as the identity pivot's `accountId` source.
  defp user_find_by_email_request(args, _ctx) do
    [params: %{"query" => args["email"]}]
  end

  defp user_find_by_email_response(s, body) when s in 200..299 do
    case users_list(body) do
      [first | _] -> {:ok, %{"user" => normalise_user(first)}}
      []          -> {:ok, %{"user" => %{}}}
    end
  end

  defp users_list(body) when is_list(body), do: body
  defp users_list(_),                       do: []

  defp normalise_user(u) do
    %{
      "accountId"    => Map.get(u, "accountId"),
      "emailAddress" => Map.get(u, "emailAddress"),
      "displayName"  => Map.get(u, "displayName")
    }
  end

  # ─── page.find — GET /content ─────────────────────────────────────────

  defp page_find_request(args, _ctx) do
    params =
      %{"spaceKey" => args["space_key"], "type" => "page"}
      |> maybe_put_kv("title", Map.get(args, "title"))
      |> maybe_put_kv("limit", Map.get(args, "limit"))

    [params: params]
  end

  defp page_find_response(s, body) when s in 200..299 do
    pages =
      body
      |> pages_list()
      |> Enum.map(&normalise_page/1)

    {:ok, %{"pages" => pages}}
  end

  defp pages_list(%{"results" => list}) when is_list(list), do: list
  defp pages_list(_), do: []

  defp normalise_page(p) do
    %{
      "id"        => to_string(Map.get(p, "id") || ""),
      "title"     => Map.get(p, "title"),
      "space_key" => p |> Map.get("space", %{}) |> Map.get("key")
    }
  end

  # ─── page.create — POST /content ──────────────────────────────────────

  defp page_create_request(args, _ctx) do
    body = %{
      "type"  => "page",
      "title" => args["title"],
      "space" => %{"key" => args["space_key"]},
      "body"  => %{
        "storage" => %{
          "value"          => args["body_storage"],
          "representation" => "storage"
        }
      }
    }

    [json: body]
  end

  defp page_create_response(s, body) when s in 200..299 do
    {:ok, %{"page_id" => to_string(Map.get(body, "id") || "")}}
  end

  # ─── page.update — PUT /content/{page_id} ─────────────────────────────

  defp page_update_url(args),
    do: "#{@confluence_base}/content/#{safe_path_id(args["page_id"])}"

  defp page_update_request(args, _ctx) do
    body =
      %{
        "type"    => "page",
        "version" => %{"number" => args["version_number"]}
      }
      |> maybe_put_kv("title", Map.get(args, "title"))
      |> maybe_put_body_storage(Map.get(args, "body_storage"))

    [json: body]
  end

  defp maybe_put_body_storage(map, nil), do: map
  defp maybe_put_body_storage(map, ""),  do: map
  defp maybe_put_body_storage(map, value) do
    Map.put(map, "body", %{
      "storage" => %{"value" => value, "representation" => "storage"}
    })
  end

  defp page_update_response(s, body) when s in 200..299 do
    {:ok, %{"page_id" => to_string(Map.get(body, "id") || "")}}
  end

  # ─── page.delete — DELETE /content/{page_id} ──────────────────────────

  defp page_delete_url(args),
    do: "#{@confluence_base}/content/#{safe_path_id(args["page_id"])}"

  defp page_delete_request(_args, _ctx), do: []

  defp page_delete_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── space.find — GET /space ──────────────────────────────────────────

  defp space_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "limit", Map.get(args, "limit"))
    [params: params]
  end

  defp space_find_response(s, body) when s in 200..299 do
    spaces =
      body
      |> spaces_list()
      |> Enum.map(&normalise_space/1)

    {:ok, %{"spaces" => spaces}}
  end

  defp spaces_list(%{"results" => list}) when is_list(list), do: list
  defp spaces_list(_), do: []

  defp normalise_space(sp) do
    %{
      "id"   => to_string(Map.get(sp, "id") || ""),
      "key"  => Map.get(sp, "key"),
      "name" => Map.get(sp, "name")
    }
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  # Build a `AND status = '<value>'` clause from a free-text status.
  # Returns "" when no status was supplied.
  defp status_clause(nil), do: ""
  defp status_clause(""),  do: ""
  defp status_clause(s),   do: " AND status = #{jql_quote(s)}"

  # JQL string literals are single-quoted. Escape backslash FIRST
  # (otherwise an input backslash would consume the escape we add for
  # a following quote and let it break out of the literal), then
  # escape the single quote. Closes the JQL-injection vector on
  # `issue.find`.
  defp jql_quote(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'" <> escaped <> "'"
  end

  # Whitelist a path-param id to the Atlassian id charset before
  # interpolating it into a URL. A value that doesn't match raises —
  # the dispatcher surfaces it as an error envelope rather than
  # building a URL with an injected segment / query string.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid atlassian id: #{inspect(id)}"
    end
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
