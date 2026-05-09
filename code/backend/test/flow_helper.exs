# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Test.FlowHelper do
  @moduledoc """
  Shared profile-aware setup for flow tests under `test/flows/`.

  Each flow file calls `setup_profile/1` from its `setup_all` block,
  passing the flow's id (e.g. "F11"). This module:

    1. Reads `TEST_PROFILE` env (default `"stub"`).
    2. In stub mode: loads the flow's tape and installs `LLMStub`.
    3. In llm mode: pins `swiftModel` and `assistantModel` to the cheap
       ollama-cloud pair (`ministral-3:14b` + `devstral-small-2:24b`),
       and verifies the pool exists with at least one credentialed
       account.
    4. In stub-record mode (`TEST_PROFILE=llm` + `TEST_RECORD=1`):
       LLMStub captures responses as it runs; on test exit the tape
       is written to disk.
    5. Returns an `on_exit` callback that the test must register to
       restore Application env / settings rows.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @tape_dir Path.expand("flow_tapes", __DIR__)

  @cheap_swift_model "ollama-cloud::ministral-3:14b"
  @cheap_assistant_model "ollama-cloud::devstral-small-2:24b"

  @doc """
  Set up the LLM environment for `flow_id`. Returns a 0-arity teardown
  callback the test should register via `on_exit/1`.
  """
  def setup_profile(flow_id) do
    case {profile(), recording?()} do
      {"stub", _} ->
        setup_stub(flow_id, recording?: false)

      {"llm", true} ->
        chain_teardown(setup_stub(flow_id, recording?: true), setup_llm())

      {"llm", false} ->
        setup_llm()

      {other, _} ->
        raise "Unknown TEST_PROFILE=#{inspect(other)}; expected stub|llm"
    end
  end

  def profile, do: System.get_env("TEST_PROFILE", "stub")
  def recording?, do: System.get_env("TEST_RECORD") in ["1", "true", "yes"]

  # ── stub mode ────────────────────────────────────────────────────────

  defp setup_stub(flow_id, recording?: rec?) do
    tape_path = Path.join(@tape_dir, "#{flow_id}.tape.json")

    tape =
      cond do
        rec? -> []
        File.exists?(tape_path) ->
          tape_path
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("turns")

        true ->
          raise """
          Tape missing for flow_id=#{flow_id} at #{tape_path}.
          Run with `mix flow #{flow_id} --profile llm --record` to create it.
          """
      end

    record_path = if rec?, do: tape_path, else: nil
    pid = DmhAi.Test.LLMStub.install(flow_id, tape, record_path: record_path)

    fn -> DmhAi.Test.LLMStub.stop(pid) end
  end

  # ── llm mode ─────────────────────────────────────────────────────────

  defp setup_llm do
    assert_ollama_cloud_pool!()
    prior = snapshot_settings(["swiftModel", "assistantModel"])
    write_settings(%{
      "swiftModel"     => @cheap_swift_model,
      "assistantModel" => @cheap_assistant_model
    })

    fn -> restore_settings(prior) end
  end

  defp assert_ollama_cloud_pool! do
    %{rows: rows} = query!(Repo,
      "SELECT accounts FROM pools WHERE name = ?", ["ollama-cloud"])

    case rows do
      [[accounts_json]] ->
        case Jason.decode(accounts_json || "[]") do
          {:ok, accts} when accts != [] ->
            non_empty_keys =
              Enum.any?(accts, fn a ->
                k = Map.get(a, "api_key") || ""
                is_binary(k) and byte_size(k) > 8
              end)

            unless non_empty_keys do
              raise "TEST_PROFILE=llm requires ollama-cloud pool with at least one accounts entry holding a real api_key. Found accounts but no usable key. Run `curl -XPUT http://127.0.0.1:8080/ai_pools --data-binary @pools.json` first."
            end

          _ ->
            raise "TEST_PROFILE=llm requires ollama-cloud pool with at least one account. Found pool row but no accounts. Run `curl -XPUT http://127.0.0.1:8080/ai_pools --data-binary @pools.json` first."
        end

      [] ->
        raise "TEST_PROFILE=llm requires an ollama-cloud pool to be configured. None found in the pools table. Run `curl -XPUT http://127.0.0.1:8080/ai_pools --data-binary @pools.json` first."
    end
  end

  defp snapshot_settings(keys) do
    Enum.reduce(keys, %{}, fn k, acc ->
      %{rows: rows} = query!(Repo, "SELECT value FROM settings WHERE key=?", [k])
      Map.put(acc, k, case rows do
        [[v]] -> v
        _     -> nil
      end)
    end)
  end

  defp write_settings(map) do
    Enum.each(map, fn {k, v} ->
      query!(Repo,
        "INSERT INTO settings (key, value) VALUES (?, ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [k, v])
    end)
  end

  defp restore_settings(prior) do
    Enum.each(prior, fn
      {k, nil} -> query!(Repo, "DELETE FROM settings WHERE key=?", [k])
      {k, v}   -> write_settings(%{k => v})
    end)
  end

  defp chain_teardown(f1, f2), do: fn -> f1.(); f2.() end
end
