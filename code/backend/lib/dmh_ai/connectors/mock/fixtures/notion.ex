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
      "page.find"          => &page_find/1,
      "page.get"           => &page_get/1,
      "page.create"        => &page_create/1,
      "page.update"        => &page_update/1,
      "page.archive"       => &page_archive/1,
      "block.append"       => &block_append/1,
      "block.get"          => &block_get/1,
      "block.delete"       => &block_delete/1,
      "database.find"      => &database_find/1,
      "database.query"     => &database_query/1,
      "database.create"    => &database_create/1,
      "database.update"    => &database_update/1,
      "comment.create"     => &comment_create/1,
      "comment.find"       => &comment_find/1,
      "user.list"          => &user_list/1,
      "user.find_by_email" => &user_find_by_email/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      page_id:            "00000000-mock-page-0000-000000000001",
      page_title:         "Beispiel-Seite Demo",
      database_id:        "00000000-mock-db00-0000-000000000001",
      database_new_id:    "00000000-mock-db-create-001",
      comment_id:         "00000000-mock-cmnt-0000-000000000001",
      block_id:           "00000000-mock-block-001",
      notion_user_id:     "00000000-mock-user-0000-000000000001",
      notion_user_email:  "klara.beispiel@beispiel-team-demo.example"
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

  # Notion's soft-delete echoes the archived page object at the top
  # level; the connector's response parser maps the `id` to `page_id`.
  defp page_archive(_args) do
    %{page_id: id} = sentinels()

    %{"object" => "page", "id" => id, "archived" => true}
  end

  defp block_get(_args) do
    %{block_id: id} = sentinels()

    %{
      "object"  => "list",
      "results" => [%{"object" => "block", "id" => id, "type" => "paragraph"}]
    }
  end

  defp block_delete(_args) do
    %{block_id: id} = sentinels()

    %{"object" => "block", "id" => id, "archived" => true}
  end

  defp database_create(_args) do
    %{database_new_id: id} = sentinels()

    %{"object" => "database", "id" => id}
  end

  defp database_update(_args) do
    %{database_id: id} = sentinels()

    %{"object" => "database", "id" => id}
  end

  defp comment_find(_args) do
    %{comment_id: id} = sentinels()

    %{
      "object"  => "list",
      "results" => [
        %{
          "object" => "comment",
          "id"     => id,
          "rich_text" => [%{"text" => %{"content" => "Beispiel-Kommentar."}}]
        }
      ]
    }
  end

  defp user_list(_args) do
    %{notion_user_id: id, notion_user_email: email} = sentinels()

    %{
      "object"  => "list",
      "results" => [
        %{
          "object" => "user",
          "id"     => id,
          "type"   => "person",
          "person" => %{"email" => email}
        }
      ]
    }
  end

  # The custom handler's wire shape is the same `GET /users` paginated
  # response — the fixture serves that, and the handler does the
  # client-side email match against `person.email`.
  defp user_find_by_email(_args) do
    user_list(%{})
  end
end
