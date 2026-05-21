# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.EphemeralCacheTest do
  @moduledoc """
  Pins the contract of `DmhAi.Agent.EphemeralCache` and the two
  modules layered on top (`StreamBuffer`, `ThinkingBuffer`). The
  key invariant: streaming state is in ETS, NOT the DB. No SQLite
  write per token. See architecture.md §Streaming state lives in
  ETS, not the DB.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Agent.{EphemeralCache, StreamBuffer, ThinkingBuffer}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    sid = "ec_test_" <> T.uid()
    uid = "ec_user_" <> T.uid()

    on_exit(fn ->
      EphemeralCache.delete(sid, :stream)
      EphemeralCache.delete(sid, :thinking)
    end)

    {:ok, session_id: sid, user_id: uid}
  end

  describe "EphemeralCache primitives" do
    test "put / get round-trip", %{session_id: sid} do
      assert EphemeralCache.get(sid, :stream) == nil
      :ok = EphemeralCache.put(sid, :stream, "hello", 1)
      assert {"hello", 1} = EphemeralCache.get(sid, :stream)
    end

    test "put overwrites the previous value", %{session_id: sid} do
      :ok = EphemeralCache.put(sid, :stream, "v1", 1)
      :ok = EphemeralCache.put(sid, :stream, "v2", 2)
      assert {"v2", 2} = EphemeralCache.get(sid, :stream)
    end

    test "delete removes the entry", %{session_id: sid} do
      :ok = EphemeralCache.put(sid, :stream, "x", 1)
      :ok = EphemeralCache.delete(sid, :stream)
      assert EphemeralCache.get(sid, :stream) == nil
    end

    test ":stream and :thinking are independent kinds", %{session_id: sid} do
      :ok = EphemeralCache.put(sid, :stream, "answer", 1)
      :ok = EphemeralCache.put(sid, :thinking, "chain of thought", 2)
      assert {"answer", 1}            = EphemeralCache.get(sid, :stream)
      assert {"chain of thought", 2}  = EphemeralCache.get(sid, :thinking)

      :ok = EphemeralCache.delete(sid, :stream)
      assert EphemeralCache.get(sid, :stream)   == nil
      assert {"chain of thought", 2} = EphemeralCache.get(sid, :thinking)
    end
  end

  describe "StreamBuffer" do
    test "flush + read + clear round-trip — no SQL touched",
         %{session_id: sid, user_id: uid} do
      # Tightly bracket: read sessions row count writes. Before this
      # block runs, no row exists for this synthetic sid. We assert
      # the row count stays at zero — confirms ZERO DB writes from
      # the streaming path.
      [[before]] = query!(Repo, "SELECT COUNT(*) FROM sessions WHERE id=?", [sid]).rows
      assert before == 0

      buf = StreamBuffer.new(sid, uid)
      buf = StreamBuffer.append(buf, "Hello")
      buf = StreamBuffer.append(buf, ", world!")
      buf = StreamBuffer.flush(buf)

      assert StreamBuffer.read(sid, uid) == "Hello, world!"
      assert buf.last_flush_ms > 0

      [[after_]] = query!(Repo, "SELECT COUNT(*) FROM sessions WHERE id=?", [sid]).rows
      assert after_ == 0, "streaming flush must NOT write to sessions table"

      :ok = StreamBuffer.clear(sid, uid)
      assert StreamBuffer.read(sid, uid) == ""
    end

    test "maybe_flush respects the 250 ms throttle",
         %{session_id: sid, user_id: uid} do
      buf = StreamBuffer.new(sid, uid)
      buf = StreamBuffer.append(buf, "x")

      buf2 = StreamBuffer.maybe_flush(buf)
      assert buf2.last_flush_ms > 0
      # Within 250 ms, last_flush_ms must not move on a no-op maybe_flush.
      buf3 = StreamBuffer.maybe_flush(buf2)
      assert buf3.last_flush_ms == buf2.last_flush_ms
    end

    test "read returns empty string on miss (FE-contract preserved)",
         %{session_id: sid, user_id: uid} do
      assert StreamBuffer.read(sid, uid) == ""
    end
  end

  describe "ThinkingBuffer" do
    test "writes to :thinking kind, distinct from :stream",
         %{session_id: sid, user_id: uid} do
      _sb = StreamBuffer.new(sid, uid) |> StreamBuffer.append("answer") |> StreamBuffer.flush()
      _tb = ThinkingBuffer.new(sid, uid) |> ThinkingBuffer.append("thought") |> ThinkingBuffer.flush()

      assert StreamBuffer.read(sid, uid)   == "answer"
      assert ThinkingBuffer.read(sid, uid) == "thought"

      :ok = ThinkingBuffer.clear(sid, uid)
      assert StreamBuffer.read(sid, uid)   == "answer"   # untouched
      assert ThinkingBuffer.read(sid, uid) == ""

      :ok = StreamBuffer.clear(sid, uid)
    end
  end

  describe "concurrent writers (the original failure scenario)" do
    test "100 concurrent flushes don't crash anything, all see consistent reads",
         %{session_id: sid, user_id: uid} do
      tasks =
        for n <- 1..100 do
          Task.async(fn ->
            buf = StreamBuffer.new(sid, uid)
            buf = StreamBuffer.append(buf, "chunk-#{n}")
            _ = StreamBuffer.flush(buf)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      # The exact last-writer-wins value is non-deterministic, but
      # SOMETHING got persisted, no crashes raised.
      text = StreamBuffer.read(sid, uid)
      assert is_binary(text)
      assert String.starts_with?(text, "chunk-")

      :ok = StreamBuffer.clear(sid, uid)
    end
  end

  describe "PRAGMA busy_timeout" do
    test "is set to a non-zero value on this connection" do
      %{rows: [[v]]} = query!(Repo, "PRAGMA busy_timeout", [])
      assert is_integer(v) and v >= 5000,
             "busy_timeout must be ≥ 5000 ms — SQLite must wait briefly for the writer slot " <>
               "instead of raising SQLITE_BUSY. Got #{v}."
    end
  end
end
