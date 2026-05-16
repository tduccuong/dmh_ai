# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.ManifestVerifier do
  @moduledoc """
  Dev-time tool that diffs a connector's `manifest/0` against the
  vendor's actual `tools/list` payload. Closes the I3 audit loop
  by making "functions are vendor-grounded" mechanically checkable
  instead of trust-based.

  Not invoked at runtime. Used from `iex` or test setups during a
  per-connector grounding audit:

      iex> {:ok, %{"tools" => tools}} = DmhAi.MCP.Client.list_tools(user_id, "google_workspace")
      iex> DmhAi.Connectors.ManifestVerifier.diff(DmhAi.Connectors.GoogleWorkspace, tools)
      %{
        missing: [],            # in manifest, NOT in vendor
        extra:   ["gmail.draft"], # in vendor, NOT in manifest
        present: ["gmail.search", "gmail.send", ...]
      }

  The verifier compares function NAMES only. Arg-shape and return-shape
  divergences need a separate review (per-function integration tests
  serve that role — they fail loudly if the wrapper-layer
  translation in the connector code disagrees with the real MCP).
  """

  alias DmhAi.Tools.Manifest

  @typedoc "Diff result. All values are sorted, deduplicated lists of function names."
  @type diff :: %{
          missing: [String.t()],
          extra:   [String.t()],
          present: [String.t()]
        }

  @doc """
  Compare the connector module's manifest functions to the vendor's
  `tools/list` response. `tools/list` is given as the raw list
  inside `result.tools` — i.e. `[%{"name" => name, ...}, ...]`.
  """
  @spec diff(module(), [map()]) :: diff()
  def diff(connector_mod, tools) when is_atom(connector_mod) and is_list(tools) do
    %Manifest{functions: functions} = connector_mod.manifest()
    manifest_set = functions |> Map.keys() |> MapSet.new()
    vendor_set =
      tools
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [name]
        _ -> []
      end)
      |> MapSet.new()

    %{
      missing: MapSet.difference(manifest_set, vendor_set) |> Enum.sort(),
      extra:   MapSet.difference(vendor_set, manifest_set) |> Enum.sort(),
      present: MapSet.intersection(manifest_set, vendor_set) |> Enum.sort()
    }
  end

  @doc """
  Pretty-print a diff for the iex console / log review. Returns a
  multi-line string.
  """
  @spec format(diff()) :: String.t()
  def format(%{missing: m, extra: e, present: p}) do
    """
    Manifest vs vendor tools/list diff:
      present (#{length(p)}): #{Enum.join(p, ", ")}
      missing in vendor (#{length(m)}): #{Enum.join(m, ", ")}
      extra from vendor (#{length(e)}): #{Enum.join(e, ", ")}
    """
  end
end
