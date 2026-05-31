# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.References do
  @moduledoc """
  Deep validation: Mustache references resolve.

  The validator extracts every `{{ref}}` from any string in any
  node's args, runs each through `Workflows.Path.parse/1`, and checks:

    * `:trigger` root — the leading path key is declared in the
      trigger node's `inputs[]` (or matches the leading segment of a
      dotted-name input like `deal.id`).
    * `{:node, n}` root — node id `n` exists AND its `emits` map
      declares the leading path key.
    * `:owner` / `:org` / `:now` / `:today` — built-in bindings; no
      further check.

  All ref discovery + parsing lives in `Workflows.Refs` /
  `Workflows.Mustache` / `Workflows.Path` — single-pass state
  machines, no regex. See `arch_wiki/dmh_ai/sme/layer-W.md`
  §Mustache + Path grammar.
  """

  alias DmhAi.Tools.UpsertWorkflow.RequiredArgs
  alias DmhAi.Workflows.Refs

  @doc """
  Validate every `{{ref}}` carried by any node's `args`, `emit`,
  or branch `cases[].when`. Returns the first invalid reference
  with a teaching error, or `:ok` if all references resolve.
  """
  @spec check_references(map(), [map()]) :: :ok | {:error, String.t()}
  def check_references(_ir, nodes) do
    trigger_input_keys =
      nodes
      |> Enum.find(fn n -> n["kind"] == "trigger" end)
      |> case do
        nil -> []
        t   -> t |> Map.get("inputs", []) |> Enum.map(& &1["name"])
      end

    declared_ids   = nodes |> Enum.map(& &1["id"])
    declared_emits = collect_emits(nodes)

    nodes
    |> Enum.flat_map(fn node ->
      # Walk every value that may carry refs: `args` (step nodes),
      # `emit` (output nodes), and `cases[].when` (branch nodes).
      sources = [
        Map.get(node, "args", %{}),
        Map.get(node, "emit", %{}),
        Map.get(node, "cases", [])
      ]

      sources
      |> Enum.flat_map(&Refs.extract/1)
      |> Enum.map(&{node["id"], &1})
    end)
    |> Enum.reduce_while(:ok, fn {node_id, entry}, _acc ->
      case validate_ref(entry, trigger_input_keys, declared_ids, declared_emits) do
        :ok ->
          {:cont, :ok}

        {:error, why} ->
          {:halt,
           {:error,
            "upsert_workflow: node #{node_id} reference `{{#{Map.get(entry, :raw)}}}` — #{why}"}}
      end
    end)
  end

  @doc """
  Known emit keys per node = explicit `emits` keys ∪ the keys the
  function's manifest declares it `returns:`. Downstream refs may
  bind against either — the explicit map (for aliased deep paths)
  or the implicit set (for direct passthrough of the connector's
  declared response shape). This makes the `emits` field optional
  whenever the connector contract already names the field; the
  model never repeats what the manifest already promises.
  """
  @spec collect_emits([map()]) :: %{any() => [String.t()]}
  def collect_emits(nodes) do
    Enum.reduce(nodes, %{}, fn n, acc ->
      explicit =
        case Map.get(n, "emits") do
          e when is_map(e) -> Map.keys(e)
          _                -> []
        end

      implicit = function_returns_keys(Map.get(n, "function"))

      Map.put(acc, n["id"], Enum.uniq(explicit ++ implicit))
    end)
  end

  @doc """
  Top-level keys the function's manifest declares it returns. nil
  / missing → []. Used by `collect_emits/1` to credit downstream
  refs against the manifest's declared `returns:` shape without
  the IR having to repeat them in an `emits` map.
  """
  @spec function_returns_keys(any()) :: [String.t()]
  def function_returns_keys(nil), do: []
  def function_returns_keys(fn_name) when is_binary(fn_name) do
    case RequiredArgs.function_spec(fn_name) do
      %{returns: r} when is_map(r) -> r |> Map.keys() |> Enum.map(&to_string/1)
      _ -> []
    end
  end
  def function_returns_keys(_), do: []

  @doc """
  Resolve a single extracted `{{ref}}` entry against the IR's
  declared trigger inputs, node ids, and emit keys.
  """
  @spec validate_ref(map(), [String.t()], [any()], %{any() => [String.t()]}) ::
          :ok | {:error, String.t()}
  # Each entry from `Refs.extract/1` is either a parsed ref or a
  # parser error (carried through so we can surface a precise
  # diagnostic for the model).
  def validate_ref(%{error: reason}, _t_keys, _ids, _emits),
    do: {:error, reason}

  def validate_ref(%{parsed: %{root: :trigger, path: path}}, t_keys, _ids, _emits) do
    case path do
      [{:key, key} | _rest] ->
        if key in t_keys do
          :ok
        else
          # Allow trigger inputs declared with a leading dotted name
          # (e.g. `deal.id` — declared key is the WHOLE dotted string,
          # and a ref like `T.deal.id` walks past it as two segments).
          # Match against the leading segment OR the full declared
          # name's leading segment.
          if Enum.any?(t_keys, fn declared ->
               leading = declared |> String.split(".") |> List.first()
               leading == key
             end) do
            :ok
          else
            {:error, "no matching trigger input (declared: #{inspect(t_keys)})"}
          end
        end

      [] ->
        {:error, "trigger ref needs at least one path segment"}

      _ ->
        {:error, "trigger ref must start with a key segment"}
    end
  end

  def validate_ref(%{parsed: %{root: {:node, n}, path: path}}, _t_keys, ids, emits) do
    cond do
      not Enum.member?(ids, n) ->
        {:error, "node id #{n} not declared"}

      path == [] ->
        {:error, "node reference needs at least one path segment after `#{n}.`"}

      true ->
        case path do
          [{:key, key} | _rest] ->
            if Enum.member?(Map.get(emits, n, []), key) do
              :ok
            else
              {:error, "node #{n} doesn't declare emit `#{key}` " <>
                "(check the function's manifest `returns:` for the available top-level keys; " <>
                "for nested fields, declare `emits: {#{key}: \"$.<jsonpath>\"}` on node #{n})"}
            end

          [{:index, _i} | _rest] ->
            # Index-first path against a node emit is unusual but not
            # nonsensical (e.g. when the emit is a top-level list).
            # The validator can't know the runtime shape, so allow it.
            :ok
        end
    end
  end

  # `:org` accepts org-level facts only (`{{org.name}}`, `{{org.id}}`).
  # The legacy `{{org.me.<x>}}` alias was an indirection for the
  # owner's record; it's been replaced by `{{owner.<x>}}` (DMH-AI app
  # identity) and `{{owner.<slug>.email}}` (per-connector vendor
  # identity). Reject the legacy form at compile time with explicit
  # remediation pointing at the current binding.
  def validate_ref(%{parsed: %{root: :org, path: [{:key, "me"} | _]}},
                    _t_keys, _ids, _emits) do
    {:error,
     "`{{org.me.<x>}}` is not a valid binding. Use `{{owner.<x>}}` for the " <>
       "workflow owner's DMH-AI app identity (e.g. `{{owner.email}}`), or " <>
       "`{{owner.<slug>.email}}` (substituting the connector's slug) for the " <>
       "owner's vendor identity captured at OAuth time."}
  end

  def validate_ref(%{parsed: %{root: root}}, _t_keys, _ids, _emits)
       when root in [:owner, :org, :now, :today] do
    :ok
  end

  # Relative-time roots (`{{now-7d}}`, `{{today+1w}}`) — the offset is
  # already validated by the grammar; nothing to resolve against here.
  def validate_ref(%{parsed: %{root: {base, _offset}}}, _t_keys, _ids, _emits)
       when base in [:now, :today] do
    :ok
  end

  # `:local` roots are template-local placeholders — the synthetic
  # primitive (or whatever consumer) resolves them at run time. The
  # validator has nothing to check against; pass through.
  def validate_ref(%{parsed: %{root: :local}}, _t_keys, _ids, _emits), do: :ok
end
