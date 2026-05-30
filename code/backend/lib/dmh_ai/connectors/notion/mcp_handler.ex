# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Notion.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Notion connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a Notion
  REST endpoint at `https://api.notion.com/v1/*`:

    page.find          — POST   /search (filter object=page)
    page.get           — GET    /pages/{page_id}
    page.create        — POST   /pages
    page.update        — PATCH  /pages/{page_id}
    page.archive       — PATCH  /pages/{page_id}  (body archived=true)
    block.append       — PATCH  /blocks/{block_id}/children
    block.get          — GET    /blocks/{block_id}/children
    block.delete       — DELETE /blocks/{block_id}
    database.find      — POST   /search (filter object=database)
    database.query     — POST   /databases/{database_id}/query
    database.create    — POST   /databases
    database.update    — PATCH  /databases/{database_id}
    comment.create     — POST   /comments
    comment.find       — GET    /comments?block_id=…
    user.list          — GET    /users
    user.find_by_email — paginated GET /users + client-side filter

  Fixed host (`https://api.notion.com/v1`), no per-instance
  templating. Standard `Authorization: Bearer <token>` auth, which
  `RestBridge` injects from `ctx.bearer_token`.

  ## `user.find_by_email` — soft cap

  Notion exposes no native email-pivot endpoint. `user.find_by_email`
  is implemented as a custom handler that fans out paginated
  `GET /users` calls (capped at `@email_lookup_page_cap` pages of
  `@email_lookup_page_size` users each) and filters client-side for
  `person.email == email`. Beyond the cap the user is treated as
  not found; the soft cap exists so a workspace with thousands of
  members doesn't blow up the call.

  ## The `Notion-Version` header

  Every Notion request MUST carry `{"Notion-Version", "2022-06-28"}`
  or it is rejected with a 400. So EVERY `request` builder here emits
  that header (alongside its `:json` / `:params` options) — including
  the read GETs, which otherwise would need no request transform.
  `version_headers/0` is the single source for the header list.

  ## Path-param ids

  Functions acting on a specific object interpolate the id into the
  path via a `:url` function `(args -> url)`. Notion ids are UUIDs
  *with dashes*, so the id is whitelisted to `^[A-Za-z0-9-]+$` before
  the URL is built (`safe_path_id/1`) — no raw interpolation of
  unvalidated input.

  ## Error body

  Notion returns normal HTTP status codes; the `RestBridge` keys
  success off the 2xx status. On a 4xx/5xx Notion frames a JSON body
  `%{"object" => "error", "status" => <int>, "code" => <code>,
  "message" => ...}` which the bridge surfaces and the connector's
  `remap_error/1` maps to the canonical class.
  """

  alias DmhAi.Connectors.MCPServer.{FunctionSpec, RestBridge}
  require Logger

  @api_base "https://api.notion.com/v1"

  # Every Notion request carries this header or it 400s. Kept in sync
  # with the same constant in `DmhAi.Connectors.Notion`.
  @notion_version "2022-06-28"

  # Notion object ids are UUIDs with dashes. Whitelist the charset
  # (allowing the hyphen) before interpolating into a URL path so an
  # attacker can't inject path segments or query strings via a lookup
  # arg.
  @path_id_re ~r/^[A-Za-z0-9-]+$/

  # `user.find_by_email` page-fanout caps. Notion has no native
  # email pivot, so the handler paginates `/users` and filters
  # client-side; these caps bound the work per call.
  @email_lookup_page_size 100
  @email_lookup_page_cap  3

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1`
  at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "notion", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "page.find" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/search",
        request: &page_find_request/2,
        response: &page_find_response/2,
        doc:     "Search for pages."
      },
      "page.get" => %FunctionSpec{
        method:  :get,
        url:     &page_get_url/1,
        request: &page_get_request/2,
        response: &page_get_response/2,
        doc:     "Read one page by id."
      },
      "page.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/pages",
        request: &page_create_request/2,
        response: &page_create_response/2,
        doc:     "Create a page under a parent."
      },
      "page.update" => %FunctionSpec{
        method:  :patch,
        url:     &page_update_url/1,
        request: &page_update_request/2,
        response: &page_update_response/2,
        doc:     "Patch a page's properties."
      },
      "block.append" => %FunctionSpec{
        method:  :patch,
        url:     &block_append_url/1,
        request: &block_append_request/2,
        response: &block_append_response/2,
        doc:     "Append child blocks to a block/page."
      },
      "database.find" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/search",
        request: &database_find_request/2,
        response: &database_find_response/2,
        doc:     "Search for databases."
      },
      "database.query" => %FunctionSpec{
        method:  :post,
        url:     &database_query_url/1,
        request: &database_query_request/2,
        response: &database_query_response/2,
        doc:     "Query rows of a database."
      },
      "comment.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/comments",
        request: &comment_create_request/2,
        response: &comment_create_response/2,
        doc:     "Add a comment to a page."
      },
      "page.archive" => %FunctionSpec{
        method:  :patch,
        url:     &page_archive_url/1,
        request: &page_archive_request/2,
        response: &page_archive_response/2,
        doc:     "Soft-delete a page (set archived=true)."
      },
      "database.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/databases",
        request: &database_create_request/2,
        response: &database_create_response/2,
        doc:     "Create a database under a parent page."
      },
      "database.update" => %FunctionSpec{
        method:  :patch,
        url:     &database_update_url/1,
        request: &database_update_request/2,
        response: &database_update_response/2,
        doc:     "Patch a database (title / properties / description)."
      },
      "block.get" => %FunctionSpec{
        method:  :get,
        url:     &block_get_url/1,
        request: &block_get_request/2,
        response: &block_get_response/2,
        doc:     "Read children of a block (or page)."
      },
      "block.delete" => %FunctionSpec{
        method:  :delete,
        url:     &block_delete_url/1,
        request: &block_delete_request/2,
        response: &block_delete_response/2,
        doc:     "Soft-archive a block."
      },
      "user.list" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/users",
        request: &user_list_request/2,
        response: &user_list_response/2,
        doc:     "List workspace users."
      },
      "user.find_by_email" => %FunctionSpec{
        handler: &user_find_by_email/2,
        doc:     "Resolve a workspace user by email (paginated /users filter)."
      },
      "comment.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/comments",
        request: &comment_find_request/2,
        response: &comment_find_response/2,
        doc:     "List comments under a block (or page)."
      }
    }
  end

  # ─── page.find — POST /search (filter object=page) ────────────────────

  defp page_find_request(args, _ctx) do
    body =
      %{"filter" => %{"property" => "object", "value" => "page"}}
      |> maybe_put_kv("query", Map.get(args, "query"))
      |> maybe_put_kv("page_size", Map.get(args, "limit"))

    [json: body, headers: version_headers()]
  end

  defp page_find_response(s, body) when s in 200..299 do
    {:ok, %{"pages" => results(body)}}
  end

  # ─── page.get — GET /pages/{page_id} ──────────────────────────────────

  defp page_get_url(args), do: "#{@api_base}/pages/#{safe_path_id(args["page_id"])}"

  # A read GET needs no body, but Notion still requires the version
  # header — so the request transform exists solely to inject it.
  defp page_get_request(_args, _ctx), do: [headers: version_headers()]

  defp page_get_response(s, body) when s in 200..299 do
    {:ok, %{"page" => obj(body)}}
  end

  # ─── page.create — POST /pages ────────────────────────────────────────

  defp page_create_request(args, _ctx) do
    parent_type = Map.get(args, "parent_type") || "page_id"

    body = %{
      "parent"     => %{parent_type => args["parent_id"]},
      "properties" => %{
        "title" => %{
          "title" => [%{"text" => %{"content" => args["title"]}}]
        }
      }
    }

    [json: body, headers: version_headers()]
  end

  defp page_create_response(s, body) when s in 200..299 do
    {:ok, %{"page_id" => to_string(obj(body)["id"])}}
  end

  # ─── page.update — PATCH /pages/{page_id} ─────────────────────────────

  defp page_update_url(args), do: "#{@api_base}/pages/#{safe_path_id(args["page_id"])}"

  defp page_update_request(args, _ctx) do
    [json: %{"properties" => args["patch"] || %{}}, headers: version_headers()]
  end

  defp page_update_response(s, body) when s in 200..299 do
    {:ok, %{"page_id" => to_string(obj(body)["id"])}}
  end

  # ─── block.append — PATCH /blocks/{block_id}/children ─────────────────

  defp block_append_url(args),
    do: "#{@api_base}/blocks/#{safe_path_id(args["block_id"])}/children"

  defp block_append_request(args, _ctx) do
    [json: %{"children" => args["children"] || []}, headers: version_headers()]
  end

  defp block_append_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── database.find — POST /search (filter object=database) ────────────

  defp database_find_request(args, _ctx) do
    body =
      %{"filter" => %{"property" => "object", "value" => "database"}}
      |> maybe_put_kv("query", Map.get(args, "query"))
      |> maybe_put_kv("page_size", Map.get(args, "limit"))

    [json: body, headers: version_headers()]
  end

  defp database_find_response(s, body) when s in 200..299 do
    {:ok, %{"databases" => results(body)}}
  end

  # ─── database.query — POST /databases/{database_id}/query ─────────────

  defp database_query_url(args),
    do: "#{@api_base}/databases/#{safe_path_id(args["database_id"])}/query"

  defp database_query_request(args, _ctx) do
    body = maybe_put_kv(%{}, "page_size", Map.get(args, "limit"))
    [json: body, headers: version_headers()]
  end

  defp database_query_response(s, body) when s in 200..299 do
    {:ok, %{"results" => results(body)}}
  end

  # ─── comment.create — POST /comments ──────────────────────────────────

  defp comment_create_request(args, _ctx) do
    body = %{
      "parent"    => %{"page_id" => args["page_id"]},
      "rich_text" => [%{"text" => %{"content" => args["text"]}}]
    }

    [json: body, headers: version_headers()]
  end

  defp comment_create_response(s, body) when s in 200..299 do
    {:ok, %{"comment_id" => to_string(obj(body)["id"])}}
  end

  # ─── page.archive — PATCH /pages/{page_id} (archived=true) ────────────

  defp page_archive_url(args), do: "#{@api_base}/pages/#{safe_path_id(args["page_id"])}"

  defp page_archive_request(_args, _ctx) do
    [json: %{"archived" => true}, headers: version_headers()]
  end

  defp page_archive_response(s, body) when s in 200..299 do
    {:ok, %{"page_id" => to_string(obj(body)["id"])}}
  end

  # ─── database.create — POST /databases ────────────────────────────────

  defp database_create_request(args, _ctx) do
    body = %{
      "parent"     => %{"type" => "page_id", "page_id" => args["parent_page_id"]},
      "title"      => [%{"type" => "text", "text" => %{"content" => args["title"]}}],
      "properties" => args["properties"] || %{}
    }

    [json: body, headers: version_headers()]
  end

  defp database_create_response(s, body) when s in 200..299 do
    {:ok, %{"database_id" => to_string(obj(body)["id"])}}
  end

  # ─── database.update — PATCH /databases/{database_id} ─────────────────

  defp database_update_url(args),
    do: "#{@api_base}/databases/#{safe_path_id(args["database_id"])}"

  defp database_update_request(args, _ctx) do
    [json: args["patch"] || %{}, headers: version_headers()]
  end

  defp database_update_response(s, body) when s in 200..299 do
    {:ok, %{"database_id" => to_string(obj(body)["id"])}}
  end

  # ─── block.get — GET /blocks/{block_id}/children ──────────────────────

  defp block_get_url(args),
    do: "#{@api_base}/blocks/#{safe_path_id(args["block_id"])}/children"

  defp block_get_request(args, _ctx) do
    params = maybe_put_kv(%{}, "page_size", Map.get(args, "limit"))
    [params: params, headers: version_headers()]
  end

  defp block_get_response(s, body) when s in 200..299 do
    {:ok, %{"blocks" => results(body)}}
  end

  # ─── block.delete — DELETE /blocks/{block_id} ─────────────────────────

  defp block_delete_url(args), do: "#{@api_base}/blocks/#{safe_path_id(args["block_id"])}"

  # A DELETE carries no body but Notion still requires the version
  # header — so the request transform exists solely to inject it.
  defp block_delete_request(_args, _ctx), do: [headers: version_headers()]

  defp block_delete_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── user.list — GET /users ───────────────────────────────────────────

  defp user_list_request(args, _ctx) do
    params = maybe_put_kv(%{}, "page_size", Map.get(args, "limit"))
    [params: params, headers: version_headers()]
  end

  defp user_list_response(s, body) when s in 200..299 do
    {:ok, %{"users" => results(body)}}
  end

  # ─── user.find_by_email — custom handler (paginated /users filter) ────
  #
  # Notion has no native email-pivot endpoint. Page through `/users`
  # (capped at `@email_lookup_page_cap` pages of
  # `@email_lookup_page_size` users) and filter client-side for
  # `person.email == email`. Beyond the cap, treat the user as not
  # found and return an empty `user` map.

  defp user_find_by_email(args, ctx) do
    email = args["email"]

    case scan_users_for_email(email, ctx, nil, @email_lookup_page_cap) do
      {:ok, :not_found}        -> {:ok, %{"user" => %{}}}
      {:ok, user} when is_map(user) -> {:ok, %{"user" => user}}
      {:error, _} = err        -> err
    end
  end

  # Page through `/users` up to `pages_left` cap times, looking for
  # a `person.email == email` row. Each call returns either a found
  # user, `:not_found` once the pages run out (or the vendor stops
  # paginating), or a transport / vendor error.
  defp scan_users_for_email(_email, _ctx, _cursor, 0), do: {:ok, :not_found}

  defp scan_users_for_email(email, ctx, cursor, pages_left) do
    params =
      %{"page_size" => @email_lookup_page_size}
      |> maybe_put_kv("start_cursor", cursor)

    opts = [
      url:     "#{@api_base}/users",
      params:  params,
      headers: version_headers()
    ]

    case RestBridge.raw_request(:get, opts_with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 ->
        rows = results(body)

        case Enum.find(rows, &person_email_matches?(&1, email)) do
          %{} = user ->
            {:ok, user}

          nil ->
            case next_cursor(body) do
              nil     -> {:ok, :not_found}
              ""      -> {:ok, :not_found}
              cursor2 -> scan_users_for_email(email, ctx, cursor2, pages_left - 1)
            end
        end

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp person_email_matches?(%{"person" => %{"email" => row_email}}, email)
       when is_binary(row_email) and is_binary(email),
       do: String.downcase(row_email) == String.downcase(email)

  defp person_email_matches?(_, _), do: false

  defp next_cursor(%{"next_cursor" => cur}) when is_binary(cur), do: cur
  defp next_cursor(_), do: nil

  defp opts_with_bearer(opts, %{bearer_token: token}) when is_binary(token) and token != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"authorization", "Bearer " <> token} | headers])
  end

  defp opts_with_bearer(opts, _), do: opts

  # ─── comment.find — GET /comments?block_id=… ──────────────────────────

  defp comment_find_request(args, _ctx) do
    params =
      %{"block_id" => args["block_id"]}
      |> maybe_put_kv("page_size", Map.get(args, "limit"))

    [params: params, headers: version_headers()]
  end

  defp comment_find_response(s, body) when s in 200..299 do
    {:ok, %{"comments" => results(body)}}
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  # The mandatory `Notion-Version` header, emitted by every request
  # builder. `RestBridge` prepends the bearer-auth header to whatever
  # list a builder returns, so these two coexist.
  defp version_headers, do: [{"Notion-Version", @notion_version}]

  # Notion search / query endpoints wrap rows under a `"results"` list.
  # Tolerates an already-unwrapped body (defensive) and a missing key.
  defp results(%{"results" => list}) when is_list(list), do: list
  defp results(_), do: []

  # Single-resource reads / writes return the object at the top level
  # (`/pages/{id}` is the page object itself). Tolerates a non-map body.
  defp obj(body) when is_map(body), do: body
  defp obj(_), do: %{}

  # Whitelist a path-param id to the Notion id charset (UUID with
  # dashes) before interpolating it into a URL. A value that doesn't
  # match raises — the dispatcher surfaces it as an error envelope
  # rather than building a URL with an injected segment / query string.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid notion id: #{inspect(id)}"
    end
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
