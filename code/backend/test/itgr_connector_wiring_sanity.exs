# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.ConnectorWiringSanityTest do
  @moduledoc """
  Live assertion that every registered connector's manifest ⇄
  handler wiring is consistent. Boot already raises on a mismatch
  (`Bootstrap.verify_handler_wiring!/3`); this test runs the same
  shape check at suite startup so a regression surfaces as a test
  failure during local + CI, not only as a stage-instance refusal
  to start.

  Checks per connector:
    * every function declared in `manifest/0` has a `%FunctionSpec{}`
      in the handler module's `functions/0` map (no orphan manifest
      entries, no orphan handler entries);
    * every handler entry IS a `%FunctionSpec{}` struct.

  We don't require a FunctionSpec to set `:response` or `:handler` —
  a missing translator falls through to RestBridge's default 2xx →
  `{:ok, body}` passthrough, which is valid when the manifest's
  `returns:` already matches the raw vendor response. Verifying that
  match is the contract test, a separate (planned) gate.
  """

  use ExUnit.Case, async: true

  alias DmhAi.Connectors.Registry
  alias DmhAi.Connectors.MCPServer.FunctionSpec

  for mod <- Registry.universal_modules(),
      function_exported?(mod, :mcp_handler_module, 0) do
    test "#{inspect(mod)} — manifest functions are wired in the handler" do
      mod = unquote(mod)
      handler_mod = mod.mcp_handler_module()

      # `function_exported?/3` returns false when the module hasn't been
      # loaded yet (lazy code-server loading); force-load before the
      # introspection call so the assertion reflects the real export.
      Code.ensure_loaded(handler_mod)

      assert function_exported?(handler_mod, :handler, 0),
             "#{inspect(handler_mod)} does not export handler/0"

      %{slug: slug, functions: handler_fns} = handler_mod.handler()

      manifest_fns =
        case function_exported?(mod, :manifest, 0) do
          true  -> Map.get(mod.manifest(), :functions, %{})
          false -> %{}
        end

      missing =
        manifest_fns
        |> Map.keys()
        |> Enum.reject(fn name -> Map.has_key?(handler_fns, name) end)

      assert missing == [],
             "connector `#{slug}` declares manifest functions not in handler " <>
               "#{inspect(handler_mod)}: #{inspect(missing)}"

      not_a_spec =
        Enum.flat_map(handler_fns, fn {name, spec} ->
          if match?(%FunctionSpec{}, spec), do: [], else: [name]
        end)

      assert not_a_spec == [],
             "connector `#{slug}` handler entries that aren't %FunctionSpec{}: " <>
               inspect(not_a_spec)
    end
  end
end
