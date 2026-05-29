# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Notion do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Notion connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  These return Notion's *raw* wire shape — search / query reads wrap
  rows under a top-level `"results"` list; single-resource reads /
  writes return the object itself with a top-level `"id"`. That keeps
  the fixtures faithful to the vendor and lets the connector's
  `response` parsers exercise their unwrap.

  Sentinel identifiers (obviously-fake UUID-shaped Notion page /
  database / comment ids + a fake page title) let runbooks + tests
  assert mechanically that the chain's output came from the
  connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "page.find"      => &page_find/1,
      "page.get"       => &page_get/1,
      "page.create"    => &page_create/1,
      "page.update"    => &page_update/1,
      "block.append"   => &block_append/1,
      "database.find"  => &database_find/1,
      "database.query" => &database_query/1,
      "comment.create" => &comment_create/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      page_id:       "00000000-mock-page-0000-000000000001",
      page_title:    "Beispiel-Seite Demo",
      database_id:   "00000000-mock-db00-0000-000000000001",
      comment_id:    "00000000-mock-cmnt-0000-000000000001"
    }
  end

  # ── Per-function fixtures (raw Notion wire shapes) ───────────────────

  defp page_find(_args) do
    %{page_id: id, page_title: title} = sentinels()

    %{
      "results" => [
        %{
          "object" => "page",
          "id"     => id,
          "url"    => "https://www.notion.so/" <> title
        }
      ]
    }
  end

  defp page_get(_args) do
    %{page_id: id, page_title: title} = sentinels()

    %{
      "object" => "page",
      "id"     => id,
      "url"    => "https://www.notion.so/" <> title
    }
  end

  defp page_create(_args) do
    %{page_id: id} = sentinels()

    %{
      "object" => "page",
      "id"     => id <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp page_update(_args) do
    %{page_id: id} = sentinels()

    %{"object" => "page", "id" => id}
  end

  defp block_append(_args) do
    %{page_id: id} = sentinels()

    %{
      "object"  => "list",
      "results" => [%{"object" => "block", "id" => id}]
    }
  end

  defp database_find(_args) do
    %{database_id: id} = sentinels()

    %{
      "results" => [
        %{
          "object" => "database",
          "id"     => id
        }
      ]
    }
  end

  defp database_query(_args) do
    %{page_id: id} = sentinels()

    %{
      "object"  => "list",
      "results" => [%{"object" => "page", "id" => id}]
    }
  end

  defp comment_create(_args) do
    %{comment_id: id} = sentinels()

    %{
      "object" => "comment",
      "id"     => id
    }
  end
end
