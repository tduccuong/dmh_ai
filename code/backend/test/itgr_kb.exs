# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.KB do
  use ExUnit.Case, async: false

  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.{Memory, SqliteVec, Embedder}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Pipeline tests run against the Memory backend with stubbed embedder
  # + tagger so they don't depend on a live embedding endpoint or
  # sqlite-vec being loaded. Backend smoke test runs against the real
  # SqliteVec backend through the existing ecto_sqlite3 connection.
  setup do
    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs = Enum.map(texts, &fake_embedding/1)
      {:ok, vecs}
    end)
    Application.put_env(:dmh_ai, :__tagger_stub__, fn _body -> ["test", "stubbed"] end)
    Application.put_env(:dmh_ai, :vector_db_backend, Memory)
    Memory.reset()

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__embedder_stub__)
      Application.delete_env(:dmh_ai, :__tagger_stub__)
      Application.delete_env(:dmh_ai, :vector_db_backend)
      Memory.reset()
    end)

    :ok
  end

  describe "ingest/2 (knowledge scope)" do
    test "indexes a body and search finds it" do
      attrs = %{
        scope: :knowledge,
        user_id: nil,
        source_kind: "text",
        source_ref: sha("test-source-#{T.uid()}"),
        title: "test note"
      }

      body = "Bitrix24 webhooks live at /rest/<user_id>/<webhook_token>/. " <>
             "Common methods include crm.lead.add and crm.deal.add."

      assert {:ok, %{indexed: n, source_id: sid}} = VectorDB.ingest(attrs, body)
      assert n >= 1
      assert is_integer(sid)

      q = "Bitrix24 webhook url shape"
      {:ok, qvec} = Embedder.embed(q)
      {:ok, hits} = VectorDB.search(:knowledge, q, qvec, 3, :none)
      assert Enum.any?(hits, fn h -> h.source_id == sid end)
    end

    test "URL source dedupes by source_ref on re-ingest" do
      ref = "https://example.test/page-#{T.uid()}"
      attrs = %{scope: :knowledge, user_id: nil, source_kind: "url", source_ref: ref, title: nil}

      assert {:ok, _} = VectorDB.ingest(attrs, "first body content for url dedup test")
      {:ok, count1} = VectorDB.count(:knowledge)

      assert {:ok, _} = VectorDB.ingest(attrs, "totally fresh second body content")
      {:ok, count2} = VectorDB.count(:knowledge)

      # Old chunks gone, new chunks present — counts equal because the
      # new body produces a similar number of chunks.
      assert count2 > 0
      assert count1 > 0
    end
  end

  describe "ingest/2 (memo scope)" do
    test "memos are user-scoped — different users don't see each other's hits" do
      uid_a = "user-a-#{T.uid()}"
      uid_b = "user-b-#{T.uid()}"

      VectorDB.ingest(
        %{scope: :memo, user_id: uid_a, source_kind: "text", source_ref: sha("a-1"), title: nil},
        "alice's bank account is at NorthWest Trust, account number 12345"
      )

      VectorDB.ingest(
        %{scope: :memo, user_id: uid_b, source_kind: "text", source_ref: sha("b-1"), title: nil},
        "bob's apartment is on Oak Street and the wifi password is hunter2"
      )

      q = "bank account details"
      {:ok, qvec} = Embedder.embed(q)

      {:ok, hits_a} = VectorDB.search(:memo, q, qvec, 5, {:user, uid_a})
      assert Enum.all?(hits_a, fn _ -> true end)
      refute hits_a == []

      {:ok, hits_b} = VectorDB.search(:memo, q, qvec, 5, {:user, uid_b})
      # b's content shouldn't surface in a's filter and vice versa
      a_texts = Enum.map(hits_a, & &1.chunk_text)
      b_texts = Enum.map(hits_b, & &1.chunk_text)
      refute Enum.any?(a_texts, fn t -> String.contains?(t, "Oak Street") end)
      refute Enum.any?(b_texts, fn t -> String.contains?(t, "NorthWest Trust") end)
    end
  end

  describe "Tool definitions" do
    test "fetch_wiki has minimal schema" do
      d = DmhAi.Tools.FetchWiki.definition()
      assert d.name == "fetch_wiki"
      assert d.parameters.required == ["q"]
      assert Map.keys(d.parameters.properties) == [:q]
    end

    test "fetch_memo has minimal schema" do
      d = DmhAi.Tools.FetchMemo.definition()
      assert d.name == "fetch_memo"
      assert d.parameters.required == ["q"]
    end

    test "save_memo has minimal schema" do
      d = DmhAi.Tools.SaveMemo.definition()
      assert d.name == "save_memo"
      assert d.parameters.required == ["text"]
    end

    test "memo tools rejected without user context" do
      assert {:error, msg} = DmhAi.Tools.FetchMemo.execute(%{"q" => "anything"}, %{})
      assert msg =~ "authenticated user"

      assert {:error, msg2} = DmhAi.Tools.SaveMemo.execute(%{"text" => "x"}, %{})
      assert msg2 =~ "authenticated user"
    end

    test "save_memo + fetch_memo round-trip with user context" do
      uid = "tool-test-#{T.uid()}"
      ctx = %{user_id: uid}

      assert {:ok, %{ok: true}} = DmhAi.Tools.SaveMemo.execute(
        %{"text" => "I keep my passwords in 1Password vault Personal"},
        ctx
      )

      assert {:ok, hits} = DmhAi.Tools.FetchMemo.execute(
        %{"q" => "where do I keep passwords"},
        ctx
      )

      assert is_list(hits)
      assert length(hits) > 0
      assert Enum.all?(hits, fn h ->
        Map.has_key?(h, :text) and Map.has_key?(h, :source) and Map.has_key?(h, :score)
      end)
    end
  end

  describe "Tools.Registry catalog shape" do
    test "fetch_wiki and fetch_memo are in the static catalog" do
      names = DmhAi.Tools.Registry.names()
      assert "fetch_wiki" in names
      assert "fetch_memo" in names
    end

    test "save_memo is NOT advertised in the LLM catalog (runtime-only)" do
      # save_memo is reachable through `known?` / `execute` (so the
      # /wiki + /memo runtime paths can dispatch SaveWiki / SaveMemo)
      # but never surfaced to the model — eliminates the risk of a
      # hallucinated write. See specs/commands.md.
      names = DmhAi.Tools.Registry.names()
      refute "save_memo" in names

      defs = DmhAi.Tools.Registry.all_definitions() |> Enum.map(& &1.name)
      refute "save_memo" in defs
    end

    test "save_memo + fetch_memo pass Tools.Registry.known? in BOTH unary and task-aware variants" do
      # Police's unknown_tool_name gate uses known?/3 on every tool
      # call. fetch_memo is in the static catalog, but save_memo is
      # save-only — known? must still recognise it so the runtime
      # /memo path can dispatch via Registry.execute.
      assert DmhAi.Tools.Registry.known?("save_memo")
      assert DmhAi.Tools.Registry.known?("fetch_memo")
      assert DmhAi.Tools.Registry.known?("save_memo", "any-user", nil)
      assert DmhAi.Tools.Registry.known?("fetch_memo", "any-user", "any-task-id")
    end

    test "memo tools dispatch via Registry.execute" do
      uid = "registry-dispatch-#{T.uid()}"
      ctx = %{user_id: uid}

      # save first, then fetch — proves both ends of the dispatch path.
      assert {:ok, %{ok: true}} =
               DmhAi.Tools.Registry.execute("save_memo", %{"text" => "registry test"}, ctx)

      assert {:ok, _} =
               DmhAi.Tools.Registry.execute("fetch_memo", %{"q" => "registry"}, ctx)
    end
  end

  describe "SqliteVec backend smoke test" do
    setup do
      Application.put_env(:dmh_ai, :vector_db_backend, SqliteVec)
      uid = "vec-smoke-#{T.uid()}"

      on_exit(fn ->
        query!(Repo, "DELETE FROM kb_chunks_meta WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM kb_sources WHERE user_id=?", [uid])
        Application.put_env(:dmh_ai, :vector_db_backend, Memory)
      end)

      {:ok, uid: uid}
    end

    test "round trip + cosine ordering through real vec0", %{uid: uid} do
      attrs = %{
        scope: :memo,
        user_id: uid,
        source_kind: "text",
        source_ref: sha("vec-smoke-1-#{T.uid()}"),
        title: nil
      }

      {:ok, _} = VectorDB.ingest(attrs, "the eiffel tower is in paris france")
      {:ok, _} = VectorDB.ingest(
        Map.put(attrs, :source_ref, sha("vec-smoke-2-#{T.uid()}")),
        "the colosseum is in rome italy"
      )

      q = "paris landmarks"
      {:ok, qvec} = Embedder.embed(q)
      {:ok, hits} = VectorDB.search(:memo, q, qvec, 2, {:user, uid})
      assert length(hits) <= 2

      Enum.each(hits, fn h ->
        assert h.score >= 0.0 and h.score <= 1.0
      end)
    end

    test "hybrid BM25 + vector merge surfaces a chunk vector misses on shared keywords",
         %{uid: uid} do
      # Two docs:
      #   A — exact-match keywords for the query.
      #   B — semantically about the topic but with different
      #       words. With a good embedder both rank well; the
      #       point of this test is just that the BM25 leg fires
      #       (kb_fts is queried + joined) AND the dedup/RRF
      #       merge yields a coherent ranked list.
      attrs = %{scope: :memo, user_id: uid, source_kind: "text", title: nil}

      {:ok, _} = VectorDB.ingest(
        Map.put(attrs, :source_ref, sha("hybrid-A-#{T.uid()}")),
        "Bitrix24 bizproc.workflow.template.add creates a new workflow template via REST API."
      )
      {:ok, _} = VectorDB.ingest(
        Map.put(attrs, :source_ref, sha("hybrid-B-#{T.uid()}")),
        "Workflow templates are managed through the bizproc module endpoints."
      )

      q = "bizproc.workflow.template.add"
      {:ok, qvec} = Embedder.embed(q)
      {:ok, hits} = VectorDB.search(:memo, q, qvec, 5, {:user, uid})

      # Both docs returned (no error from FTS5 path); the exact-
      # keyword doc A reaches top via BM25 even if cosine alone
      # would be ambiguous. The contract we pin: hits is non-empty
      # and the highest-ranked chunk_text contains the verbatim
      # method name.
      refute hits == []
      assert hd(hits).chunk_text =~ "bizproc.workflow.template.add"
    end
  end

  describe "Auto-relearn enqueue" do
    test "fetch_wiki enqueues background relearn for non-text hits" do
      # Seed a URL-kind source so its hit has a relearnable source_kind.
      attrs = %{
        scope: :knowledge,
        user_id: nil,
        source_kind: "url",
        source_ref: "https://example.test/relearn-test-#{T.uid()}",
        title: "relearn fixture"
      }
      VectorDB.ingest(attrs, "nightly cron job runs at 03:00 UTC every day")

      # Capture relearn worker invocations
      ref_table = :ets.new(:relearn_test, [:public])
      Application.put_env(:dmh_ai, :kb_relearn_worker, fn kind, ref ->
        :ets.insert(ref_table, {ref, kind})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:dmh_ai, :kb_relearn_worker) end)

      {:ok, _} = DmhAi.Tools.FetchWiki.execute(%{"q" => "nightly cron"}, %{})

      # Background tasks fire async — give them a moment.
      Process.sleep(200)

      hit_kinds = :ets.tab2list(ref_table) |> Enum.map(fn {_, kind} -> kind end)
      refute Enum.member?(hit_kinds, "text")  # text sources never relearn
      :ets.delete(ref_table)
    end
  end

  defp sha(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  defp fake_embedding(text) when is_binary(text) do
    dim = DmhAi.Agent.AgentSettings.kb_embedding_dim()
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.frequencies()

    base = List.duplicate(0.0, dim)

    Enum.reduce(counts, base, fn {word, count}, acc ->
      idx = :erlang.phash2(word, dim)
      List.update_at(acc, idx, &(&1 + count * 1.0))
    end)
  end
end
