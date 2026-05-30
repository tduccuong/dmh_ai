# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03HubSpotFunctionsTest do
  @moduledoc """
  Pins every HubSpot function against the mock vendor MCP server.
  Sibling to the GW + M365 function suites — same proof pattern:
  each assertion checks a fixture-only sentinel string in the
  response so its presence proves the dispatch path reached the
  mock rather than the model inventing similar-sounding output.

  Read functions (no task gate): contact.find · deal.find.
  Write functions (task required + idempotency_key):
  contact.create · deal.create · deal.update · activity.log.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.Mock.Fixtures.HubSpot, as: HubSpotFixtures
  alias DmhAi.Connectors.HubSpot
  alias DmhAi.Tools.Dispatcher

  @slug "hubspot"
  @canonical "mock-hubspot-resource"

  setup do
    Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
    Dispatcher.reset()
    :ok = Dispatcher.register(HubSpot)

    %{url: mock_url} = T.start_mock_vendor("hubspot_functions_test", HubSpotFixtures.fixtures())
    user_id = T.transient_user()
    :ok = T.seed_mcp_authorization(user_id, @slug, @canonical, mock_url)

    {:ok, %{user_id: user_id, sentinels: HubSpotFixtures.sentinels()}}
  end

  describe "read functions (free chat, no task required)" do
    test "contact.find returns the fixture contact by email + name",
         %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"contacts" => contacts}} =
               Dispatcher.call("hubspot.contact.find",
                               %{"query" => "Mustermann"},
                               %{user_id: user_id})

      assert Enum.any?(contacts, fn c -> c["email"] == s.contact_email end)
      assert Enum.any?(contacts, fn c -> c["name"]  == s.contact_name  end)
    end

    test "deal.find returns the fixture deal", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"deals" => deals}} =
               Dispatcher.call("hubspot.deal.find",
                               %{"stage" => s.deal_stage},
                               %{user_id: user_id})

      assert Enum.any?(deals, fn d -> d["id"] == s.deal_id end)
      assert Enum.any?(deals, fn d -> d["name"] == s.deal_name end)
    end
  end

  describe "write functions (require active task + carry idempotency_key)" do
    test "contact.create inside a task returns a generated contact id",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-contact", step_seq: 0}

      assert {:ok, %{"contact_id" => cid, "email" => email}} =
               Dispatcher.call("hubspot.contact.create",
                               %{"email" => s.contact_email, "first_name" => "Klara"},
                               ctx)

      assert is_binary(cid) and String.starts_with?(cid, s.contact_id)
      assert email == s.contact_email
    end

    test "deal.create inside a task returns a generated deal id",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-deal", step_seq: 0}

      assert {:ok, %{"deal_id" => did, "name" => name}} =
               Dispatcher.call("hubspot.deal.create",
                               %{
                                 "contact_id" => s.contact_id,
                                 "amount"     => 12_500,
                                 "name"       => "Demo deal"
                               },
                               ctx)

      assert is_binary(did) and String.starts_with?(did, s.deal_id)
      assert name == "Demo deal"
    end

    test "deal.update inside a task echoes the patched keys",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-deal-update", step_seq: 0}

      assert {:ok, %{"deal_id" => did, "updated" => updated}} =
               Dispatcher.call("hubspot.deal.update",
                               %{
                                 "deal_id" => s.deal_id,
                                 "patch"   => %{"dealstage" => "closedwon", "amount" => "16000"}
                               },
                               ctx)

      assert did == s.deal_id
      assert "dealstage" in updated
      assert "amount" in updated
    end

    test "activity.log inside a task returns a generated activity id",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-act", step_seq: 0}

      assert {:ok, %{"activity_id" => aid}} =
               Dispatcher.call("hubspot.activity.log",
                               %{
                                 "deal_id" => s.deal_id,
                                 "kind"    => "call",
                                 "body"    => "Customer agreed to scope; sending follow-up."
                               },
                               ctx)

      assert is_binary(aid) and String.starts_with?(aid, s.activity_id)
    end

    test "contact.update inside a task echoes the patched keys",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-contact-update", step_seq: 0}

      assert {:ok, %{"contact_id" => cid, "updated" => updated}} =
               Dispatcher.call("hubspot.contact.update",
                               %{
                                 "contact_id" => s.contact_id,
                                 "patch"      => %{"jobtitle" => "VP Engineering"}
                               },
                               ctx)

      assert cid == s.contact_id
      assert "jobtitle" in updated
    end

    test "company.create inside a task returns a generated company id",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-company-create", step_seq: 0}

      assert {:ok, %{"company_id" => cid, "name" => name}} =
               Dispatcher.call("hubspot.company.create",
                               %{"name" => "Demo company", "domain" => "demo.example"},
                               ctx)

      assert is_binary(cid) and String.starts_with?(cid, s.company_id)
      assert name == "Demo company"
    end

    test "company.update inside a task echoes the patched keys",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-company-update", step_seq: 0}

      assert {:ok, %{"company_id" => cid, "updated" => updated}} =
               Dispatcher.call("hubspot.company.update",
                               %{
                                 "company_id" => s.company_id,
                                 "patch"      => %{"industry" => "Software"}
                               },
                               ctx)

      assert cid == s.company_id
      assert "industry" in updated
    end

    test "task.create inside a task returns a generated task id",
         %{user_id: user_id, sentinels: s} do
      ctx = %{user_id: user_id, task_id: "t-hs-task-create", step_seq: 0}

      assert {:ok, %{"task_id" => tid}} =
               Dispatcher.call("hubspot.task.create",
                               %{
                                 "subject"    => "Follow up with Brian",
                                 "body"       => "Send the proposal by Friday.",
                                 "deal_id"    => s.deal_id,
                                 "priority"   => "high",
                                 "task_type"  => "todo"
                               },
                               ctx)

      assert is_binary(tid) and String.starts_with?(tid, s.task_id)
    end
  end

  describe "company.find as a read function (no task gate)" do
    test "returns the fixture company by name", %{user_id: user_id, sentinels: s} do
      assert {:ok, %{"companies" => companies}} =
               Dispatcher.call("hubspot.company.find",
                               %{"query" => "Mustermann"},
                               %{user_id: user_id})

      assert Enum.any?(companies, fn c -> c["id"]   == s.company_id   end)
      assert Enum.any?(companies, fn c -> c["name"] == s.company_name end)
    end
  end

  describe "manifest verifier" do
    test "manifest functions and fixture functions agree (no drift)" do
      functions_in_manifest =
        HubSpot.manifest().functions |> Map.keys() |> Enum.sort()

      functions_in_fixtures =
        HubSpotFixtures.fixtures() |> Map.keys() |> Enum.sort()

      assert functions_in_manifest == functions_in_fixtures,
             """
             Manifest functions and fixture functions disagree.
             In manifest only: #{inspect(functions_in_manifest -- functions_in_fixtures)}
             In fixtures only: #{inspect(functions_in_fixtures -- functions_in_manifest)}
             """
    end
  end
end
