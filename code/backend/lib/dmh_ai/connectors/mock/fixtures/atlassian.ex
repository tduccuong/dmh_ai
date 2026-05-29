# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Atlassian do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Atlassian connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  The values returned here are the connector's *mapped* shapes (post
  `MCPHandler` translation), so a runbook / test asserts on the
  canonical keys (`issues`, `issue_id`, `projects`, `pages`,
  `page_id`, …), not Jira's / Confluence's raw envelopes.

  Sentinel identifiers (obviously-fake Jira project key + issue keys,
  numeric Confluence page id, fake space key + names) let runbooks +
  tests assert mechanically that the chain's output came from the
  connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "issue.find"       => &issue_find/1,
      "issue.create"     => &issue_create/1,
      "issue.update"     => &issue_update/1,
      "issue.transition" => &issue_transition/1,
      "issue.comment"    => &issue_comment/1,
      "project.find"     => &project_find/1,
      "page.find"        => &page_find/1,
      "page.create"      => &page_create/1,
      "page.update"      => &page_update/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      project_key:   "MOCKPROJ",
      project_name:  "Beispiel Mock-Projekt",
      issue_key:     "MOCKPROJ-1",
      issue_summary: "Beispiel Mock-Vorgang",
      comment_id:    "MOCKCMT0001",
      space_key:     "MOCKSPACE",
      space_name:    "Beispiel Mock-Bereich",
      page_id:       "1234567890",
      page_title:    "Beispiel Mock-Seite"
    }
  end

  # ── Per-function fixtures ────────────────────────────────────────────

  defp issue_find(_args) do
    %{issue_key: key, issue_summary: summary} = sentinels()

    %{
      "issues" => [
        %{
          "id"      => "10001",
          "key"     => key,
          "summary" => summary,
          "status"  => "To Do"
        }
      ]
    }
  end

  defp issue_create(_args) do
    %{issue_key: key} = sentinels()

    %{
      "issue_id" => "10001_" <> Integer.to_string(:erlang.unique_integer([:positive])),
      "key"      => key
    }
  end

  defp issue_update(_args) do
    %{"issue_id" => "updated"}
  end

  defp issue_transition(_args) do
    %{"ok" => true}
  end

  defp issue_comment(_args) do
    %{comment_id: id} = sentinels()

    %{
      "comment_id" => id <> "_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp project_find(_args) do
    %{project_key: key, project_name: name} = sentinels()

    %{
      "projects" => [
        %{
          "id"   => "10000",
          "key"  => key,
          "name" => name
        }
      ]
    }
  end

  defp page_find(_args) do
    %{page_id: id, page_title: title, space_key: space} = sentinels()

    %{
      "pages" => [
        %{
          "id"        => id,
          "title"     => title,
          "space_key" => space
        }
      ]
    }
  end

  defp page_create(_args) do
    %{page_id: id} = sentinels()

    %{
      "page_id" => id <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp page_update(_args) do
    %{page_id: id} = sentinels()

    %{"page_id" => id}
  end
end
