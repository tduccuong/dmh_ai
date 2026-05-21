# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowsComplexTest do
  @moduledoc """
  End-to-end integration tests against COMPLEX workflow IRs. Builds
  multi-node workflows with deeply-nested Mustache refs that exercise
  the full reference grammar (deep paths, mixed dot+bracket indexing,
  multiple refs per string, template strings). For each fixture:

    * **Validator pass**: feed the IR to `upsert_workflow` — expect
      success (or, for the negative case, a specific error).
    * **Executor pass**: feed synthetic bindings to the runtime
      `Refs.substitute/2` pipeline, verify the rendered args
      structure matches expectations.

  These tests pin the contract of the parsing engine against the
  shape real workflows produce, not against ad-hoc snippets.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Tools.UpsertWorkflow
  alias DmhAi.Workflows.{Refs, Path}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id "default"

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "wf-cplx-#{user_id}@test.local", "Test", "x:y", "user",
       @org_id, "member", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO sessions (id, name, model, messages, mode, user_id, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [session_id, "wf-cplx-test", "test:model", "[]", "assistant", user_id,
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    :ok = T.grant_all_scopes(user_id)

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, ctx: %{user_id: user_id, session_id: session_id, org_id: @org_id}}
  end

  # ─── Fixture 1: Daily Inbox Digest ──────────────────────────────────
  #
  # 5 nodes — poll trigger → branch on unread count → compose summary
  # → send email → output. Exercises:
  #   - bracket-index refs (`{{0.messages[0].subject}}`)
  #   - many refs per template string
  #   - `{{owner.email}}` built-in
  #   - branch predicate with ref
  #   - llm.compose synthetic with context map

  describe "Fixture 1 — Daily Inbox Digest (deep paths + templates)" do
    test "validator accepts the IR; executor resolves refs end-to-end",
         %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{
            "id" => 0, "kind" => "trigger",
            "trigger_kind" => "schedule", "cron" => "0 6 * * *",
            "label" => "Daily 6 AM trigger",
            "inputs" => [], "next" => 1
          },
          %{
            "id" => 1, "kind" => "step",
            "function" => "llm.compose",
            "label"    => "Compose digest from inbox messages",
            "args" => %{
              "template" =>
                "Hi {{owner.name}}, here's your daily digest:\n\n" <>
                "Top sender: {{2.messages[0].sender}} (subject: {{2.messages[0].subject}})\n" <>
                "Second:     {{2.messages[1].sender}} ({{2.messages[1].subject}})\n\n" <>
                "Total unread: {{2.unread_count}}",
              "context"  => %{
                "owner_name"     => "{{owner.name}}",
                "first_sender"   => "{{2.messages[0].sender}}",
                "first_subject"  => "{{2.messages[0].subject}}",
                "second_sender"  => "{{2.messages[1].sender}}",
                "second_subject" => "{{2.messages[1].subject}}",
                "unread_count"   => "{{2.unread_count}}"
              }
            },
            "emits" => %{"body" => "$.body", "subject" => "$.subject"},
            "next"  => 3
          },
          %{
            "id" => 2, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "label"    => "Search Gmail for unread mail",
            "args"     => %{"query" => "is:unread newer_than:1d", "limit" => 50},
            "emits"    => %{"messages" => "$.messages", "unread_count" => "$.count"},
            "next"     => 1
          },
          %{
            "id" => 3, "kind" => "step",
            "function" => "google_workspace.gmail.send",
            "label"    => "Send digest to owner",
            "args" => %{
              "to"      => "{{owner.email}}",
              "subject" => "{{1.subject}}",
              "body"    => "{{1.body}}"
            },
            "next" => 4
          },
          %{
            "id" => 4, "kind" => "output",
            "label" => "Digest sent",
            "emit"  => %{"sent_to" => "{{owner.email}}", "subject" => "{{1.subject}}"}
          }
        ],
        "outputs" => [
          %{"name" => "sent_to", "source" => "{{4.sent_to}}"},
          %{"name" => "subject", "source" => "{{4.subject}}"}
        ]
      }

      # Reorder nodes so polled-first node (id 2) precedes the compose
      # node that depends on its emits; the validator's `next` chain
      # check looks at declared ids, not ordering.

      # ── Validator pass ──
      assert {:ok, %{"name" => slug, "version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Daily Inbox Digest",
                 "name"         => "workflow_daily_inbox_digest",
                 "description"  => "Summarises unread inbox messages every morning at 6.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert slug == "workflow_daily_inbox_digest"

      # ── Executor pass — Refs.substitute against synthetic data ──
      bindings = %{
        "trigger" => %{},
        "emits" => %{
          "2" => %{
            "messages" => [
              %{"sender" => "alice@example.com", "subject" => "Q4 plan"},
              %{"sender" => "bob@example.com",   "subject" => "Re: budget"}
            ],
            "unread_count" => 12
          },
          "1" => %{
            "body"    => "Hi Owner, here's your daily digest…",
            "subject" => "Your inbox digest"
          }
        }
      }

      # node 3's args (the gmail.send step) — must resolve owner.email + 1.subject + 1.body
      send_args = ir["nodes"] |> Enum.at(3) |> Map.get("args")

      resolved = Refs.substitute(send_args, fn body ->
        case Path.parse(body) do
          {:ok, %{root: {:node, id}, path: path}} ->
            data = Map.get(bindings["emits"], to_string(id), %{})
            Path.walk(data, path)

          {:ok, %{root: :owner, path: _path}} ->
            "owner@example.com"

          _ -> :passthrough
        end
      end)

      assert resolved["to"]      == "owner@example.com"
      assert resolved["subject"] == "Your inbox digest"
      assert resolved["body"]    =~ "Hi Owner"

      # node 1's context map — every ref must resolve, deep refs included
      compose_ctx =
        ir["nodes"]
        |> Enum.at(1)
        |> get_in(["args", "context"])

      compose_resolved = Refs.substitute(compose_ctx, fn body ->
        case Path.parse(body) do
          {:ok, %{root: {:node, id}, path: path}} ->
            data = Map.get(bindings["emits"], to_string(id), %{})
            Path.walk(data, path)

          {:ok, %{root: :owner, path: [{:key, "name"}]}} ->
            "Alice"

          _ -> :passthrough
        end
      end)

      assert compose_resolved["owner_name"]     == "Alice"
      assert compose_resolved["first_sender"]   == "alice@example.com"
      assert compose_resolved["first_subject"]  == "Q4 plan"
      assert compose_resolved["second_sender"]  == "bob@example.com"
      assert compose_resolved["second_subject"] == "Re: budget"
      # Bare ref → typed return (integer 12, not string "12"). Templates
      # stringify; pure refs do not.
      assert compose_resolved["unread_count"]   == 12
    end
  end

  # ─── Fixture 2: HubSpot Deal-Close Routing ──────────────────────────
  #
  # Webhook trigger → fetch contact → fetch company → branch on country
  # → send templated email. Exercises:
  #   - DEEPLY nested refs (`{{2.companies[0].properties.country.value}}`)
  #   - branch predicates that compare ref vs literal
  #   - multiple distinct connectors
  #   - trigger inputs with dotted names (`deal.id`)

  describe "Fixture 2 — HubSpot Deal-Close Routing (deep refs + branches)" do
    test "validator accepts; executor resolves deep paths correctly",
         %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{
            "id" => 0, "kind" => "trigger", "trigger_kind" => "webhook",
            "label" => "Deal closed in HubSpot",
            "event" => "hubspot.deal.closed",
            "inputs" => [
              %{"name" => "deal.id", "type" => "string"},
              %{"name" => "deal.amount", "type" => "number"}
            ],
            "next" => 1
          },
          %{
            "id" => 1, "kind" => "step",
            "function" => "hubspot.contact.find",
            "label"    => "Look up the deal's primary contact",
            "args"     => %{"query" => "{{T.deal.id}}", "limit" => 1},
            "emits"    => %{
              "contact_id"    => "$.contacts[0].id",
              "contact_email" => "$.contacts[0].properties.email.value"
            },
            "next" => 2
          },
          %{
            "id" => 2, "kind" => "step",
            "function" => "hubspot.company.find",
            "label"    => "Look up the company linked to the contact",
            "args"     => %{"query" => "{{1.contact_id}}"},
            "emits"    => %{
              "company_country" => "$.companies[0].properties.country.value",
              "company_name"    => "$.companies[0].properties.name.value"
            },
            "next" => 3
          },
          %{
            "id" => 3, "kind" => "branch",
            "label" => "EU vs non-EU routing",
            "cases" => [
              %{"when" => "{{2.company_country}} == 'DE'", "next" => 4},
              %{"when" => "{{2.company_country}} == 'FR'", "next" => 4}
            ],
            "else" => %{"next" => 5}
          },
          %{
            "id" => 4, "kind" => "step",
            "function" => "google_workspace.gmail.send",
            "label"    => "Send GDPR-compliant deal-close email",
            "args"     => %{
              "to"      => "{{1.contact_email}}",
              "subject" => "Deal closed — GDPR notice for {{2.company_name}}",
              "body"    => "Hello, your deal {{T.deal.id}} (worth {{T.deal.amount}}) has closed."
            },
            "next" => 6
          },
          %{
            "id" => 5, "kind" => "step",
            "function" => "google_workspace.gmail.send",
            "label"    => "Send standard deal-close email",
            "args"     => %{
              "to"      => "{{1.contact_email}}",
              "subject" => "Deal closed at {{2.company_name}}",
              "body"    => "Hello, your deal {{T.deal.id}} (worth {{T.deal.amount}}) has closed."
            },
            "next" => 6
          },
          %{
            "id" => 6, "kind" => "output",
            "label" => "Routing complete",
            "emit"  => %{"notified_email" => "{{1.contact_email}}"}
          }
        ]
      }

      # ── Validator pass ──
      assert {:ok, %{"name" => slug, "version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "HubSpot Deal-Close Routing",
                 "name"         => "workflow_hubspot_deal_close_routing",
                 "description"  => "Routes a deal-closed notification based on the contact company's country.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert slug == "workflow_hubspot_deal_close_routing"

      # ── Executor pass on the GDPR-email node (node 4) ──
      bindings = %{
        "trigger" => %{
          "deal" => %{"id" => "DEAL-9001", "amount" => 50_000}
        },
        "emits" => %{
          "1" => %{
            "contact_id"    => "C-7",
            "contact_email" => "ada@lovelace.eu"
          },
          "2" => %{
            "company_country" => "DE",
            "company_name"    => "Acme GmbH"
          }
        }
      }

      gdpr_args = ir["nodes"] |> Enum.at(4) |> Map.get("args")

      resolver = fn body ->
        case Path.parse(body) do
          {:ok, %{root: :trigger, path: path}} ->
            Path.walk(bindings["trigger"], path)

          {:ok, %{root: {:node, id}, path: path}} ->
            data = Map.get(bindings["emits"], to_string(id), %{})
            Path.walk(data, path)

          _ -> :passthrough
        end
      end

      resolved = Refs.substitute(gdpr_args, resolver)

      assert resolved["to"]      == "ada@lovelace.eu"
      assert resolved["subject"] == "Deal closed — GDPR notice for Acme GmbH"
      assert resolved["body"]    == "Hello, your deal DEAL-9001 (worth 50000) has closed."
    end
  end

  # ─── Fixture 3: deeply nested data path (5+ levels) ─────────────────

  describe "Fixture 3 — Deeply nested data path (95%-case real workflow)" do
    test "9-accessor path resolves correctly through synthetic API response",
         %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{
            "id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "Manual run",
            "inputs" => [],
            "next" => 1
          },
          %{
            "id" => 1, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "label"    => "Search Gmail",
            "args"     => %{"query" => "is:unread"},
            "emits"    => %{"api" => "$"},
            "next" => 2
          },
          %{
            "id" => 2, "kind" => "step",
            "function" => "llm.compose",
            "label" => "Render template using deep refs",
            "args" => %{
              "template" =>
                "First email:\nFrom: {{1.api.data.items[0].user.profile.contact.emails[0].address}}\n" <>
                "Subject: {{1.api.data.items[0].user.profile.recent.subject}}",
              "context" => %{
                "sender"  => "{{1.api.data.items[0].user.profile.contact.emails[0].address}}",
                "subject" => "{{1.api.data.items[0].user.profile.recent.subject}}"
              }
            },
            "emits" => %{"body" => "$.body"},
            "next" => 3
          },
          %{
            "id" => 3, "kind" => "output",
            "label" => "Done",
            "emit" => %{"composed" => "{{2.body}}"}
          }
        ]
      }

      assert {:ok, _} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Deeply Nested Reference Test",
                 "name"         => "workflow_deep_ref_test",
                 "description"  => "Exercises the path parser against deeply-nested API responses.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      # ── Executor: 9-segment path resolution ──
      bindings = %{
        "trigger" => %{},
        "emits" => %{
          "1" => %{
            "api" => %{
              "data" => %{
                "items" => [
                  %{
                    "user" => %{
                      "profile" => %{
                        "contact" => %{
                          "emails" => [
                            %{"address" => "deep@nested.example", "verified" => true}
                          ]
                        },
                        "recent" => %{"subject" => "9 levels deep works"}
                      }
                    }
                  }
                ]
              }
            }
          }
        }
      }

      compose_ctx = ir["nodes"] |> Enum.at(2) |> get_in(["args", "context"])

      resolver = fn body ->
        case Path.parse(body) do
          {:ok, %{root: {:node, id}, path: path}} ->
            data = Map.get(bindings["emits"], to_string(id), %{})
            Path.walk(data, path)

          _ -> :passthrough
        end
      end

      resolved = Refs.substitute(compose_ctx, resolver)

      assert resolved["sender"]  == "deep@nested.example"
      assert resolved["subject"] == "9 levels deep works"
    end

    test "validator catches an undeclared leading emit key", %{ctx: ctx} do
      # Node 1 declares only `api` as an emit key; node 2 references
      # `1.NOT_API.foo` — leading key `NOT_API` is not declared.
      ir = %{
        "nodes" => [
          %{
            "id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "Manual", "inputs" => [], "next" => 1
          },
          %{
            "id" => 1, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "label" => "Search",
            "args"  => %{"query" => "is:unread"},
            "emits" => %{"api" => "$"},
            "next"  => 2
          },
          %{
            "id" => 2, "kind" => "output",
            "label" => "Bad ref",
            "emit" => %{"x" => "{{1.NOT_API.data.items[0].foo}}"}
          }
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad Deep Ref",
                 "name"         => "workflow_bad_deep_ref",
                 "description"  => "Should fail validation due to undeclared emit key on node 1.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "doesn't declare emit `NOT_API`"
    end

    test "validator catches a malformed bracket ref", %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{
            "id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "Manual", "inputs" => [], "next" => 1
          },
          %{
            "id" => 1, "kind" => "output",
            "label" => "Bad bracket",
            "emit" => %{"x" => "{{0.foo[abc]}}"}
          }
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad Bracket",
                 "name"         => "workflow_bad_bracket",
                 "description"  => "Should fail validation due to non-numeric content inside brackets.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "bracket" or msg =~ "only digits"
    end
  end
end
