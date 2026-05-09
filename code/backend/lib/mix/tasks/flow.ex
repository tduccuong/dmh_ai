# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Mix.Tasks.Flow do
  @moduledoc """
  Run end-to-end flow tests under `test/flows/`.

  Usage:

      mix flow                               # all flows, profile=stub
      mix flow --profile llm                 # all flows, real LLMs
      mix flow F11                           # only F11_*, profile=stub
      mix flow F11 F23                       # multiple flow ids
      mix flow F11 --profile llm --record    # rerun + capture tape

  Profiles:

    * `stub` (default) — `DmhAi.Test.LLMStub` plays back recorded tapes
      from `test/flow_tapes/<flow_id>.tape.json`. Deterministic, fast,
      no network.
    * `llm` — real LLM calls against the ollama-cloud pool, pinned to
      `ministral-3:14b` (swiftModel) and `devstral-small-2:24b`
      (assistantModel). Requires the pool to be configured with at
      least one valid api_key.

  `--record` is only meaningful with `--profile llm`. The captured
  tape replaces the existing tape file for the named flow; useful when
  prompts change and stub-mode tests start drifting.
  """

  use Mix.Task

  @shortdoc "Run end-to-end flow tests (mix flow [<flow_id>...] [--profile stub|llm] [--record])"

  @switches [profile: :string, record: :boolean]
  @aliases  [p: :profile, r: :record]

  @impl true
  def run(args) do
    {opts, positionals, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    profile = Keyword.get(opts, :profile, "stub")
    record? = Keyword.get(opts, :record, false)

    unless profile in ~w(stub llm) do
      Mix.raise("--profile must be one of: stub, llm (got #{inspect(profile)})")
    end

    if record? and profile != "llm" do
      Mix.raise("--record requires --profile llm (recording captures real LLM responses)")
    end

    System.put_env("TEST_PROFILE", profile)
    if record?, do: System.put_env("TEST_RECORD", "1")

    test_paths =
      case positionals do
        [] -> ["test/flows/"]
        ids ->
          Enum.flat_map(ids, fn id ->
            unless String.match?(id, ~r/^F\d+/) do
              Mix.raise("Flow id must look like F<NN> (got #{inspect(id)})")
            end

            Path.wildcard("test/flows/#{id}_*.exs")
          end)
      end

    if test_paths == [] do
      Mix.raise("No matching flow files for: #{inspect(positionals)}")
    end

    Mix.shell().info("[flow] profile=#{profile} record=#{record?} paths=#{inspect(test_paths)}")
    Mix.Task.run("test", test_paths)
  end
end
