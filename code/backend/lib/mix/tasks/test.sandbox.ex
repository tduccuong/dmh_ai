# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Mix.Tasks.Test.Sandbox do
  @moduledoc """
  Run the sandbox-runtime test tier under `test/sandbox/`.

  Usage:

      mix test.sandbox                     # all R<NN>_*.exs
      mix test.sandbox R01                 # only R01_*
      mix test.sandbox R01 R02             # multiple scenarios

  These tests exercise `RunScript` / `SandboxUser` / the sandbox
  container against a real docker daemon and a throwaway host
  data-dir; they're SLOW (seconds per test) and need the docker
  daemon, so they don't run on plain `mix test`.

  See architecture.md §Testing for the tier-distinction rationale and
  the full list of what's tested where.
  """

  use Mix.Task

  @shortdoc "Run sandbox-runtime tests (mix test.sandbox [R<NN>...])"

  @impl true
  def run(args) do
    test_paths =
      case args do
        [] ->
          ["test/sandbox/"]

        ids ->
          Enum.flat_map(ids, fn id ->
            unless String.match?(id, ~r/^R\d+/) do
              Mix.raise("Sandbox test id must look like R<NN> (got #{inspect(id)})")
            end

            Path.wildcard("test/sandbox/#{id}_*.exs")
          end)
      end

    if test_paths == [] do
      Mix.raise("No matching sandbox tests for: #{inspect(args)}")
    end

    Mix.shell().info("[test.sandbox] paths=#{inspect(test_paths)}")
    Mix.Task.run("test", ["--only", "sandbox" | test_paths])
  end
end
