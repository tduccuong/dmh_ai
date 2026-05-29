# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Notion.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Notion connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a Notion
  REST endpoint at `https://api.notion.com/v1/*`:

    page.find      — POST  /search (filter object=page)
    page.get       — GET   /pages/{page_id}
    page.create    — POST  /pages
    page.update    — PATCH /pages/{page_id}
    block.append   — PATCH /blocks/{block_id}/children
    database.find  — POST  /search (filter object=database)
    database.query — POST  /databases/{database_id}/query
    comment.create — POST  /comments

  Fixed host (`https://api.notion.com/v1`), no per-instance
  templating. Standard `Authorization: Bearer <token>` auth, which
  `RestBridge` injects from `ctx.bearer_token`.

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

  alias DmhAi.Connectors.MCPServer.FunctionSpec
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
