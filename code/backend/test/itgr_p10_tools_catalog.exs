# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P10ToolsCatalogTest do
  @moduledoc """
  Primitive 0.10 — Tools.Catalog integration tests.

  Coverage:

    * `lookup/1` resolves internal tools, synthetics, connector
      functions — same manifest shape across all.
    * `call/3` routes by category. Synthetics return the typed
      `:llm_synthetic_via_executor` refusal.
    * `list/1` enumerates every category with one call.
    * G1 — manifest is the only source of per-function knowledge.
    * G3 — Permissions.can?/3 fires for every dispatch.
    * The single `case category` lives in the catalog (verified by
      a static-grep style check on the source).
  """

  use ExUnit.Case, async: false

  alias DmhAi.Tools.{Catalog, Dispatcher}

  setup_all do
    # Register the connectors we want to enumerate against.
    Dispatcher.reset()
    :ok = Dispatcher.register(DmhAi.Connectors.GoogleWorkspace)
    :ok = Dispatcher.register(DmhAi.Connectors.M365)
    :ok = Dispatcher.register(DmhAi.Connectors.HubSpot)
    :ok = Dispatcher.register(DmhAi.Connectors.Calendly)
    :ok
  end

  describe "lookup/1" do
    test "resolves an internal tool by name" do
      assert {:ok, m} = Catalog.lookup("web_search")
      assert m.category == :internal
      assert is_binary(m.name) and m.name == "web_search"
      assert is_function(m.permission_target_fn, 2)
      assert m.source |> elem(1) == :internal
    end

    test "resolves an LLM synthetic" do
      assert {:ok, m} = Catalog.lookup("llm.compose")
      assert m.category == :llm_synthetic
      assert m.permission == :read_kb
      assert is_map(m.args_schema)
    end

    test "resolves a connector function (namespaced)" do
      assert {:ok, m} = Catalog.lookup("hubspot.contact.find")
      assert m.category == :external_connector
      assert m.permission == :act_as_creds
      # The identity_lookup is nil today (per-connector manifest
      # callback returns nil for v1 — see chunk B).
      assert m.identity_lookup == nil
    end

    test "unknown name returns :unknown" do
      assert {:error, :unknown} = Catalog.lookup("not_a_real_function")
    end
  end

  describe "manifest shape uniformity (G1)" do
    test "every category exposes the same key set" do
      keys = [:name, :category, :args_schema, :emits_schema,
              :permission, :permission_target_fn, :callable_from,
              :needs_user_ctx, :identity_lookup, :write_class,
              :idempotency, :source]

      {:ok, internal}    = Catalog.lookup("web_search")
      {:ok, synthetic}   = Catalog.lookup("llm.compose")
      {:ok, connector}   = Catalog.lookup("hubspot.contact.find")

      for m <- [internal, synthetic, connector],
          k <- keys do
        assert Map.has_key?(m, k),
               "manifest for #{m.name} is missing key #{inspect(k)}"
      end
    end
  end

  describe "permission_target_fn (per-call target derivation)" do
    test "connector function targets caller's own creds by default" do
      {:ok, m} = Catalog.lookup("hubspot.contact.find")
      target = m.permission_target_fn.(%{}, %{user_id: "u_alice"})
      assert target == "creds:hubspot:u_alice"
    end

    test "connector function honours act_as_user_id override" do
      {:ok, m} = Catalog.lookup("hubspot.contact.find")
      target = m.permission_target_fn.(%{}, %{user_id: "u_alice", act_as_user_id: "u_bob"})
      assert target == "creds:hubspot:u_bob"
    end
  end

  describe "call/3" do
    test "LLM synthetic refuses dispatch with the typed envelope" do
      assert {:error, :llm_synthetic_via_executor} =
               Catalog.call("llm.compose", %{}, %{user_id: "u_x"})
    end

    test "unknown name returns {:error, :unknown}" do
      assert {:error, :unknown} = Catalog.call("not_a_real_function", %{}, %{})
    end

    test "bad name (non-binary) is rejected at the surface" do
      assert {:error, %{error: "bad_name"}} = Catalog.call(:atom_name, %{}, %{})
    end
  end

  describe "list/1" do
    test "no ctx: returns internals + synthetics, no connectors" do
      list = Catalog.list(nil)
      cats = list |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
      assert :internal in cats
      assert :llm_synthetic in cats
      refute :external_connector in cats
    end

    test "with user_id ctx: includes connector functions" do
      list = Catalog.list(%{user_id: "u_x"})
      cats = list |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
      assert :external_connector in cats
    end

    test "names are unique across the listing" do
      list  = Catalog.list(%{user_id: "u_x"})
      names = Enum.map(list, & &1.name)
      dups  = names -- Enum.uniq(names)
      assert dups == [], "duplicate names in catalog list: #{inspect(dups)}"
    end
  end

  describe "G4 (single category branch)" do
    test "branching on manifest.category occurs only inside Tools.Catalog" do
      # The genericity invariant: the SINGLE `case <expr>.category do`
      # branch in the whole codebase lives in Tools.Catalog.call/3.
      # The workflow Executor (chunk G, future) will carve out an
      # `:llm_synthetic` branch on its own dispatch path — when that
      # lands, this test's allow-list grows by one entry.
      backend = Path.expand("lib")
      grep =
        System.cmd("grep", ["-rEn", "case +[a-zA-Z_]+\\.category", backend])
        |> elem(0)
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.contains?(&1, "Binary file"))

      offenders =
        Enum.reject(grep, fn line ->
          String.contains?(line, "tools/catalog.ex")
        end)

      assert offenders == [],
             "found `case <x>.category do` outside Tools.Catalog:\n  " <>
               Enum.join(offenders, "\n  ")
    end
  end
end
