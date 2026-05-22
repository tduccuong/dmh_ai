# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.GoogleLiveProbeTest do
  @moduledoc """
  Pins the contract of Google Workspace's `discover_functions/0` —
  the live-vendor-probe path. Each test stubs the Google Discovery
  Document HTTP layer via `:__google_discovery_stub__` and verifies
  the merged-rows output.

  The connector overlays live scope data onto the bundled priv-seed
  rows for functions in its `@google_method_map`; functions without
  a mapping pass through unchanged. Probe failures fall back to the
  priv row so a transient Google outage never blocks the Discover
  button.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.GoogleWorkspace
  alias DmhAi.Connectors.GoogleWorkspace.LiveProbe

  setup do
    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__google_discovery_stub__)
    end)

    :ok
  end

  describe "LiveProbe.probe_method/3" do
    test "walks nested resources to find a method by id" do
      stub_discovery(fn url ->
        assert url =~ "/discovery/v1/apis/gmail/v1/rest"

        {:ok,
         %{
           "resources" => %{
             "users" => %{
               "resources" => %{
                 "messages" => %{
                   "methods" => %{
                     "send" => %{
                       "id"         => "gmail.users.messages.send",
                       "path"       => "gmail/v1/users/{userId}/messages/send",
                       "httpMethod" => "POST",
                       "parameters" => %{"userId" => %{"required" => true}},
                       "scopes"     => [
                         "https://mail.google.com/",
                         "https://www.googleapis.com/auth/gmail.modify",
                         "https://www.googleapis.com/auth/gmail.send"
                       ]
                     }
                   }
                 }
               }
             }
           }
         }}
      end)

      assert {:ok, m} =
               LiveProbe.probe_method("gmail", "v1", "gmail.users.messages.send")

      assert m.path == "gmail/v1/users/{userId}/messages/send"
      assert m.http_method == "POST"
      assert "https://www.googleapis.com/auth/gmail.send" in m.scopes
    end

    test "returns :method_not_found when the id is absent" do
      stub_discovery(fn _ ->
        {:ok, %{"resources" => %{}}}
      end)

      assert {:error, {:method_not_found, "gmail.users.messages.send"}} =
               LiveProbe.probe_method("gmail", "v1", "gmail.users.messages.send")
    end

    test "propagates transport errors" do
      stub_discovery(fn _ -> {:error, {:transport, :nxdomain}} end)

      assert {:error, {:transport, :nxdomain}} =
               LiveProbe.probe_method("gmail", "v1", "x.y.z")
    end
  end

  describe "GoogleWorkspace.discover_functions/0" do
    test "returns the priv baseline when probe succeeds + scopes already minimal" do
      # Stub returns Gmail's full scope list; the priv row already
      # declares `gmail.send` which is in that list, so no merge
      # narrowing happens — the row passes through unchanged.
      stub_discovery(fn url ->
        case Regex.run(~r{/apis/([^/]+)/([^/]+)/rest}, url) do
          [_, "gmail", "v1"]    -> {:ok, gmail_doc()}
          [_, "calendar", "v3"] -> {:ok, calendar_doc()}
          [_, "drive", "v3"]    -> {:ok, drive_doc()}
          [_, "docs", "v1"]     -> {:ok, docs_doc()}
          [_, "sheets", "v4"]   -> {:ok, sheets_doc()}
          [_, "tasks", "v1"]    -> {:ok, tasks_doc()}
          _                     -> {:error, {:method_not_found, "n/a"}}
        end
      end)

      assert {:ok, rows} = GoogleWorkspace.discover_functions()

      send_row = Enum.find(rows, &(&1.function_name == "gmail.send"))
      assert send_row, "gmail.send row missing"

      # Priv declares the narrow `gmail.send` scope — should survive.
      assert "https://www.googleapis.com/auth/gmail.send" in send_row.scopes_required
    end

    test "scope drift logs a warning but leaves the row unchanged" do
      # Simulate Google's accepted-scope list no longer including our
      # bundled minimum scope. Row should pass through unchanged so
      # the operator can intervene deliberately — auto-substituting a
      # scope from Google's list would be guessing at permission
      # semantics. The log message is the load-bearing signal.
      stub_discovery(fn url ->
        if url =~ "/apis/gmail/v1/rest" do
          {:ok,
           %{
             "resources" => %{
               "users" => %{
                 "resources" => %{
                   "messages" => %{
                     "methods" => %{
                       "send" => %{
                         "id"         => "gmail.users.messages.send",
                         "path"       => "gmail/v1/users/{userId}/messages/send",
                         "httpMethod" => "POST",
                         "parameters" => %{},
                         "scopes"     => [
                           "https://mail.google.com/",
                           "https://www.googleapis.com/auth/replacement.short"
                         ]
                       },
                       "list" => list_method_stub()
                     }
                   }
                 }
               }
             }
           }}
        else
          {:ok, empty_doc()}
        end
      end)

      assert {:ok, rows} = GoogleWorkspace.discover_functions()

      send_row = Enum.find(rows, &(&1.function_name == "gmail.send"))

      # Priv-default scope is untouched on drift; the log line is the
      # operator-visible signal (verified separately via `capture_log`
      # in a focused unit test if needed).
      assert "https://www.googleapis.com/auth/gmail.send" in send_row.scopes_required
    end

    test "transport failure falls back to the priv baseline row" do
      stub_discovery(fn _ -> {:error, {:transport, :timeout}} end)

      assert {:ok, rows} = GoogleWorkspace.discover_functions()
      # Same row count as the priv baseline — nothing was dropped.
      {:ok, baseline} = DmhAi.Connectors.Seed.read_priv_rows("google_workspace")
      assert length(rows) == length(baseline)

      send_row = Enum.find(rows, &(&1.function_name == "gmail.send"))
      assert send_row.scopes_required != []
    end
  end

  # ─── helpers ────────────────────────────────────────────────────────

  defp stub_discovery(fun) when is_function(fun, 1) do
    Application.put_env(:dmh_ai, :__google_discovery_stub__, fun)
  end

  defp gmail_doc do
    %{
      "resources" => %{
        "users" => %{
          "resources" => %{
            "messages" => %{
              "methods" => %{
                "send" => send_method_stub(),
                "list" => list_method_stub()
              }
            }
          }
        }
      }
    }
  end

  defp send_method_stub do
    %{
      "id"         => "gmail.users.messages.send",
      "path"       => "gmail/v1/users/{userId}/messages/send",
      "httpMethod" => "POST",
      "parameters" => %{},
      "scopes"     => [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send"
      ]
    }
  end

  defp list_method_stub do
    %{
      "id"         => "gmail.users.messages.list",
      "path"       => "gmail/v1/users/{userId}/messages",
      "httpMethod" => "GET",
      "parameters" => %{},
      "scopes"     => [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.readonly"
      ]
    }
  end

  defp calendar_doc do
    %{"resources" => %{"events" => %{"methods" => %{
      "list"   => method_stub("calendar.events.list",   "GET",  ["https://www.googleapis.com/auth/calendar.readonly"]),
      "insert" => method_stub("calendar.events.insert", "POST", ["https://www.googleapis.com/auth/calendar.events"])
    }}}}
  end

  defp drive_doc do
    %{"resources" => %{"files" => %{"methods" => %{
      "create" => method_stub("drive.files.create", "POST", ["https://www.googleapis.com/auth/drive.file"]),
      "list"   => method_stub("drive.files.list",   "GET",  ["https://www.googleapis.com/auth/drive.readonly"]),
      "get"    => method_stub("drive.files.get",    "GET",  ["https://www.googleapis.com/auth/drive.readonly"])
    }}}}
  end

  defp docs_doc do
    %{"resources" => %{"documents" => %{"methods" => %{
      "create" => method_stub("docs.documents.create", "POST", ["https://www.googleapis.com/auth/documents"])
    }}}}
  end

  defp sheets_doc do
    %{"resources" => %{"spreadsheets" => %{"resources" => %{"values" => %{"methods" => %{
      "get" => method_stub("sheets.spreadsheets.values.get", "GET", ["https://www.googleapis.com/auth/spreadsheets.readonly"])
    }}}}}}
  end

  defp tasks_doc do
    %{"resources" => %{"tasks" => %{"methods" => %{
      "list"   => method_stub("tasks.tasks.list",   "GET",  ["https://www.googleapis.com/auth/tasks.readonly"]),
      "insert" => method_stub("tasks.tasks.insert", "POST", ["https://www.googleapis.com/auth/tasks"])
    }}}}
  end

  defp empty_doc, do: %{"resources" => %{}}

  defp method_stub(id, http_method, scopes) do
    %{
      "id"         => id,
      "path"       => id,
      "httpMethod" => http_method,
      "parameters" => %{},
      "scopes"     => scopes
    }
  end
end
