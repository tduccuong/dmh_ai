# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Asana do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Asana connector functions.

  Same contract as the other vendor fixtures: each value is a map
  (or 1-arg function) returning the JSON-decoded payload the MCP
  server would put inside its `content[].text` envelope.

  Unlike the other Case-B fixtures (which return already-mapped
  shapes), these return Asana's *raw* wire shape — every payload is
  wrapped in the top-level `"data"` key (`%{"data" => obj}` for a
  single resource, `%{"data" => [obj, ...]}` for a list). That keeps
  the fixtures faithful to the vendor and lets the connector's
  `response` parsers exercise their `"data"`-envelope unwrap.

  Sentinel identifiers (obviously-fake Asana project / task / user /
  story gids + a fake project name) let runbooks + tests assert
  mechanically that the chain's output came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "project.find"       => &project_find/1,
      "project.create"     => &project_create/1,
      "task.find"          => &task_find/1,
      "task.create"        => &task_create/1,
      "task.update"        => &task_update/1,
      "task.complete"      => &task_complete/1,
      "story.create"       => &story_create/1,
      "user.find"          => &user_find/1,
      "user.find_by_email" => &user_find_by_email/1,
      "workspace.find"     => &workspace_find/1,
      "team.find"          => &team_find/1,
      "section.find"       => &section_find/1,
      "section.create"     => &section_create/1,
      "task.assign"        => &task_assign/1,
      "task.delete"        => &task_delete/1,
      "subtask.find"       => &subtask_find/1,
      "subtask.create"     => &subtask_create/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      project_id:     "1200MOCKPROJ01",
      project_name:   "Beispiel-Projekt Demo",
      task_id:        "1200MOCKTASK01",
      task_name:      "Beispiel-Aufgabe Demo",
      user_id:        "1200MOCKUSER01",
      user_email:     "klara.beispiel@beispiel-team-demo.example",
      story_id:       "1200MOCKSTORY1",
      workspace_id:   "1200MOCKWS001",
      workspace_name: "Beispiel-Werkstatt GmbH",
      team_id:        "1200MOCKTEAM01",
      team_name:      "Beispiel-Team Vertrieb",
      section_id:     "1200MOCKSEC001",
      section_name:   "Beispiel-Abschnitt Eingang",
      subtask_id:     "1200MOCKSUB001",
      subtask_name:   "Beispiel-Teilaufgabe Demo"
    }
  end

  # ── Per-function fixtures (raw Asana `"data"`-envelope shapes) ────────

  defp project_find(_args) do
    %{project_id: id, project_name: name} = sentinels()

    %{
      "data" => [
        %{
          "gid"  => id,
          "name" => name
        }
      ]
    }
  end

  defp project_create(_args) do
    %{project_id: id, project_name: name} = sentinels()

    %{
      "data" => %{
        "gid"  => id <> Integer.to_string(:erlang.unique_integer([:positive])),
        "name" => name
      }
    }
  end

  defp task_find(_args) do
    %{task_id: id, task_name: name} = sentinels()

    %{
      "data" => [
        %{
          "gid"  => id,
          "name" => name
        }
      ]
    }
  end

  defp task_create(_args) do
    %{task_id: id, task_name: name} = sentinels()

    %{
      "data" => %{
        "gid"  => id <> Integer.to_string(:erlang.unique_integer([:positive])),
        "name" => name
      }
    }
  end

  defp task_update(_args) do
    %{task_id: id} = sentinels()

    %{"data" => %{"gid" => id}}
  end

  defp task_complete(_args) do
    %{task_id: id} = sentinels()

    %{"data" => %{"gid" => id, "completed" => true}}
  end

  defp story_create(_args) do
    %{story_id: id} = sentinels()

    %{
      "data" => %{
        "gid"  => id,
        "text" => "Beispiel-Kommentar an der Aufgabe."
      }
    }
  end

  defp user_find(_args) do
    %{user_id: id, user_email: email} = sentinels()

    %{
      "data" => %{
        "gid"   => id,
        "email" => email
      }
    }
  end

  # Identity pivot — sentinel email maps to a stable Asana user
  # resource so chain tests can prove the lookup was wired without
  # touching real Asana. Wrapped in `"data"` to match Asana's
  # wire-shape contract (same as every other fixture in this module).
  defp user_find_by_email(args) do
    email = Map.get(args, "email", "")

    case email do
      "mock-user@example.com" ->
        %{
          "data" => %{
            "gid"   => "MOCKASANAUSER001",
            "name"  => "Mock User",
            "email" => "mock-user@example.com"
          }
        }

      _ ->
        %{"data" => %{}}
    end
  end

  defp workspace_find(_args) do
    %{workspace_id: id, workspace_name: name} = sentinels()

    %{
      "data" => [
        %{
          "gid"           => id,
          "name"          => name,
          "is_organization" => true
        }
      ]
    }
  end

  defp team_find(_args) do
    %{team_id: id, team_name: name} = sentinels()

    %{
      "data" => [
        %{
          "gid"  => id,
          "name" => name
        }
      ]
    }
  end

  defp section_find(_args) do
    %{section_id: id, section_name: name} = sentinels()

    %{
      "data" => [
        %{
          "gid"  => id,
          "name" => name
        }
      ]
    }
  end

  defp section_create(_args) do
    %{section_id: id, section_name: name} = sentinels()

    %{
      "data" => %{
        "gid"  => id <> Integer.to_string(:erlang.unique_integer([:positive])),
        "name" => name
      }
    }
  end

  defp task_assign(_args) do
    %{task_id: id} = sentinels()

    %{"data" => %{"gid" => id, "assignee" => sentinels().user_id}}
  end

  # Asana's DELETE returns the deleted task inside `"data"`, but the
  # connector's response parser ignores the payload and maps to
  # `%{ok: true}`. The fixture mirrors the wire shape faithfully.
  defp task_delete(_args) do
    %{task_id: id} = sentinels()

    %{"data" => %{"gid" => id}}
  end

  defp subtask_find(_args) do
    %{subtask_id: id, subtask_name: name} = sentinels()

    %{
      "data" => [
        %{
          "gid"  => id,
          "name" => name
        }
      ]
    }
  end

  defp subtask_create(_args) do
    %{subtask_id: id, subtask_name: name} = sentinels()

    %{
      "data" => %{
        "gid"  => id <> Integer.to_string(:erlang.unique_integer([:positive])),
        "name" => name
      }
    }
  end
end
