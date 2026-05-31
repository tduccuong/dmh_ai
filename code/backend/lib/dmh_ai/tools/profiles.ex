# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Profiles do
  @moduledoc """
  Profile registry — the data that decides which tool modules ship
  to the LLM on a given turn.

  The full catalogue is partitioned into:

    * `:core` — always active, never deactivates. Carries the
      always-on primitives (`run_script`, `web_search`, ...) plus
      `activate_profile` (the meta-tool the model uses to load
      others).
    * `:auth`, `:workflows` — feature-grouped sets the model
      activates explicitly when the user's request hits the
      corresponding surface.
    * `:connector:<slug>` — synthesised at lookup time from the
      MCP / Universal-Region attachments of the current session.
      Each registered connector contributes one profile carrying
      its `<slug>.<function>` verbs.

  See `arch_wiki/dmh_ai/architecture.md` §Execution tools / §Tool
  profiles for the design rationale.

  This module owns the registry itself. Filtering, dispatch
  hinting, and active-set persistence live in callers
  (`Tools.Registry`, `Tools.ActivateProfile`,
  `Agent.UserAgent`).
  """

  alias DmhAi.MCP
  alias DmhAi.Connectors.Manifest, as: ConnectorManifest

  @core [
    DmhAi.Tools.ActivateProfile,
    DmhAi.Tools.WebSearch,
    DmhAi.Tools.WebFetch,
    DmhAi.Tools.WebCrawl,
    DmhAi.Tools.RunScript,
    DmhAi.Tools.ReadFile,
    DmhAi.Tools.WriteFile,
    DmhAi.Tools.Calculator,
    DmhAi.Tools.ExtractContent,
    DmhAi.Tools.LookupCreds,
    DmhAi.Tools.RequestInput,
    DmhAi.Tools.SignalBlocker,
    DmhAi.Tools.FetchIndex,
    DmhAi.Tools.FetchMemo,
    DmhAi.Tools.MkDownloadLink
  ]

  @auth [
    DmhAi.Tools.SaveCreds,
    DmhAi.Tools.DeleteCreds,
    DmhAi.Tools.AuthorizeService,
    DmhAi.Tools.ConnectMcp,
    DmhAi.Tools.ProvisionSshIdentity
  ]

  @workflows [
    DmhAi.Tools.UpsertWorkflow,
    DmhAi.Tools.ReadWorkflow,
    DmhAi.Tools.ArmWorkflow,
    DmhAi.Tools.DisarmWorkflow,
    DmhAi.Tools.InvokeWorkflow,
    DmhAi.Tools.PauseWorkflowRun,
    DmhAi.Tools.ResumeWorkflowRun,
    DmhAi.Tools.CancelWorkflowRun,
    # `inspect_function_property` fetches per-user vendor enum values
    # (calendar ids, deal stages) that vary by account and can't be
    # preloaded. A tool's STATIC contract (args + provenance + returns
    # + scopes) is inlined into its tool-def description instead — see
    # `enrich_description/2`.
    DmhAi.Tools.InspectFunctionProperty
  ]

  @doc """
  Every tool module reachable through SOME profile. Used by the
  dispatcher to look up which profile owns a given tool name when
  building the "out-of-profile" corrective error.

  Connector verbs are NOT in this list — they're resolved per-call
  via `MCP.Registry.tools_for_session/2` and grouped under
  `:connector:<slug>` synthetic profile names by the runtime.
  """
  @spec all_built_in_modules() :: [module()]
  def all_built_in_modules, do: @core ++ @auth ++ @workflows

  @doc """
  Modules in the `:core` profile. Always shipped, regardless of
  the active set.
  """
  @spec core_modules() :: [module()]
  def core_modules, do: @core

  @doc """
  Tool modules for a named built-in profile. Raises on unknown.
  Connector profiles (`:connector:<slug>`) are resolved separately
  via `connector_tools_for/2` because they're per-session and
  per-slug.
  """
  @spec built_in_modules_for(atom()) :: [module()]
  def built_in_modules_for(:core),      do: @core
  def built_in_modules_for(:auth),      do: @auth
  def built_in_modules_for(:workflows), do: @workflows

  @doc """
  List every profile name a built-in tool name belongs to. Returns
  a list because a future cross-profile tool is allowed
  (today every tool sits in exactly one profile, so the list has
  at most one entry, but the API doesn't promise that).

  Returns `[]` when the name isn't a built-in we know about (e.g.
  a connector verb, a typo, or a runtime-only save tool).
  """
  @spec profiles_for_tool_name(String.t()) :: [atom()]
  def profiles_for_tool_name(name) when is_binary(name) do
    [:core, :auth, :workflows]
    |> Enum.filter(fn p ->
      Enum.any?(built_in_modules_for(p), fn mod -> mod.name() == name end)
    end)
  end

  @doc """
  Validates a list of requested profile names against the registry.
  Each entry is either a built-in atom (`:core`, `:auth`,
  `:workflows`) or a connector profile (`"connector:<slug>"`).
  Returns `{:ok, [normalised_names]}` or `{:error, %{unknown:
  [...], valid: [...]}}` with the closest valid set for teaching.

  The caller passes a list of STRINGS (what the model produces in
  JSON args). Built-in names are parsed to atoms; connector names
  stay as strings tagged `"connector:<slug>"`.
  """
  @spec validate(list(String.t()), [String.t()]) ::
          {:ok, [atom() | {:connector, String.t()}]}
          | {:error, %{unknown: [String.t()], valid: [String.t()]}}
  def validate(requested, available_connector_slugs)
      when is_list(requested) and is_list(available_connector_slugs) do
    valid_atoms = ~w(auth workflows)a
    valid_strings = Enum.map(valid_atoms, &Atom.to_string/1) ++
                      Enum.map(available_connector_slugs, &("connector:" <> &1))

    {ok, unknown} =
      Enum.split_with(requested, fn name ->
        name in valid_strings or name == "core"
      end)

    case unknown do
      [] -> {:ok, Enum.map(ok, &normalise/1) |> Enum.uniq()}
      _  -> {:error, %{unknown: unknown, valid: valid_strings}}
    end
  end

  @doc """
  Connector verbs to include for a single connector profile name
  (`"connector:<slug>"`), drawn from the session's MCP attachments
  AND the Universal-Region dispatcher's manifest functions for the
  slug. Returns `[]` for an unattached / unknown slug — the
  validator should reject these BEFORE this is called, but the
  function is total for safety.
  """
  @spec connector_definitions_for(String.t(), String.t() | nil, String.t() | nil) :: [map()]
  def connector_definitions_for(slug, user_id, session_id) when is_binary(slug) do
    from_mcp =
      case {user_id, session_id} do
        {u, s} when is_binary(u) and is_binary(s) ->
          MCP.Registry.tools_for_session(u, s)
          |> Enum.filter(fn t -> String.starts_with?(t.name, slug <> ".") end)
          |> Enum.map(fn t ->
            %{
              name:        t.name,
              description: enrich_description(t.name, t.description),
              parameters:  t.inputSchema || %{type: "object", properties: %{}}
            }
          end)

        _ ->
          []
      end

    from_dispatcher =
      case DmhAi.Tools.Dispatcher.lookup(slug) do
        {:ok, %{manifest: %{functions: functions}}} when is_map(functions) ->
          Enum.map(functions, fn {path, fn_def} ->
            name = slug <> "." <> path
            %{
              name:        name,
              description: enrich_description(name, Map.get(fn_def, :description, "")),
              parameters:  Map.get(fn_def, :parameters,
                                   %{type: "object", properties: %{}})
            }
          end)

        _ ->
          []
      end

    # MCP entries take precedence when a name collides — the
    # session-specific attachment has the model's authoritative
    # schema for THIS user.
    mcp_names = MapSet.new(Enum.map(from_mcp, & &1.name))

    from_mcp ++ Enum.reject(from_dispatcher, fn d -> MapSet.member?(mcp_names, d.name) end)
  end

  # Append ONLY what the `parameters` JSON schema can't carry: the
  # return-key shape (so the model can bind `{{N.<key>}}`) and the
  # non-default arg sourcing rules. Arg types + `required` already
  # live in `parameters`; OAuth scopes are the validator's concern,
  # not the model's — both are omitted to keep the per-turn cost
  # down. nil manifest → base description unchanged. See
  # `arch_wiki/dmh_ai/architecture.md` §Tool profiles.
  defp enrich_description(name, base_desc) do
    base = base_desc || ""

    case ConnectorManifest.lookup_fqn(name) do
      %{} = spec ->
        line = contract_line(spec)
        if line == "", do: base, else: String.trim_trailing(base) <> "\nContract — " <> line

      _ ->
        base
    end
  end

  defp contract_line(spec) do
    [
      return_contract(Map.get(spec, :returns)),
      sourcing_contract(Map.get(spec, :args))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
  end

  # Only args whose provenance CONSTRAINS sourcing (from_user /
  # lookup / built_in) are listed — `literal_default` is the
  # permissive default and needs no mention. Keeps the line empty
  # for the common all-literal-default tool.
  defp sourcing_contract(args) when is_map(args) do
    constrained =
      args
      |> Enum.flat_map(fn {arg, meta} ->
        case Map.get(meta, :provenance) do
          %{kind: kind} when kind in [:from_user, :lookup, :built_in] -> ["#{arg}=#{kind}"]
          _ -> []
        end
      end)
      |> Enum.sort()

    case constrained do
      [] -> ""
      _  -> "source: " <> Enum.join(constrained, ", ")
    end
  end

  defp sourcing_contract(_), do: ""

  defp return_contract(returns) when is_map(returns) and map_size(returns) > 0 do
    "returns: " <> (returns |> Enum.map(fn {k, v} -> "#{k}:#{v}" end) |> Enum.sort() |> Enum.join(", "))
  end

  defp return_contract(_), do: ""

  @doc """
  Render a SHORT persistent pointer naming the profiles active on
  this chain, injected into every turn while any are active. It
  does NOT repeat the verb list — the profile's tools already ride
  in the per-turn `tools` definitions (profile-filtered; core-only
  by default), which are flush-proof. The block's job is purely to
  (a) tell the model which surfaces are loaded and (b) carry the
  "only what's in your tool defs exists — don't guess vendor-API
  names" rule that the bare tool list doesn't convey.

  Returns `nil` when no non-core profiles are active. Rebuilt each
  turn from `active_profiles`; never persisted, so it vanishes when
  the chain ends and the active set resets.
  """
  @spec format_catalog_block([String.t()]) :: String.t() | nil
  def format_catalog_block(active_profiles) when is_list(active_profiles) do
    names =
      active_profiles
      |> Enum.reject(&(&1 == "core"))
      |> Enum.uniq()

    case names do
      [] ->
        nil

      _ ->
        "<active_catalog>\nActive profiles: #{Enum.join(names, ", ")}. " <>
          "Their tools are loaded in your tool definitions — call and compose against those names.\n" <>
          "</active_catalog>"
    end
  end

  def format_catalog_block(_), do: nil

  defp normalise("core"),      do: :core
  defp normalise("auth"),      do: :auth
  defp normalise("workflows"), do: :workflows
  defp normalise("connector:" <> slug), do: {:connector, slug}

  @doc """
  Build a compact manifest for every profile in `normalised` —
  the structured catalog returned by `activate_profile` so the
  model sees exactly what verbs each profile makes callable
  without having to probe them one at a time.

  Shape per entry:

      %{
        name:    "<tool name>",
        kind:    :read | :write,
        purpose: "<short purpose; args inlined; returns named>"
      }

  Built-in profiles (`:auth`, `:workflows`) source from each
  tool module's description (first sentence). Connector profiles
  source from `Connectors.Manifest.list_for_slug/1`, falling back
  to the session's MCP attachments when the slug isn't a
  Universal-Region dispatcher entry.

  The manifest is authoritative — the system prompt teaches that
  callable verbs are EXACTLY what appears here. Verbs absent from
  the manifest are not exposed by this connector and the model
  must escalate to the user rather than guess names from training.
  """
  @spec build_manifest([atom() | {:connector, String.t()}], String.t() | nil, String.t() | nil) ::
          %{String.t() => [map()]}
  def build_manifest(normalised, user_id, session_id) do
    Enum.into(normalised, %{}, fn
      :auth      -> {"auth",      manifest_for_modules(@auth)}
      :workflows -> {"workflows", manifest_for_modules(@workflows)}

      {:connector, slug} ->
        {"connector:" <> slug, manifest_for_connector(slug, user_id, session_id)}

      _ ->
        {nil, []}
    end)
    |> Map.delete(nil)
  end

  defp manifest_for_modules(mods) do
    Enum.map(mods, fn mod ->
      Code.ensure_loaded(mod)

      kind =
        if function_exported?(mod, :catalog_manifest, 0) do
          case mod.catalog_manifest() do
            %{write_class: :write} -> :write
            _ -> :read
          end
        else
          # The `@optional_callback catalog_manifest/0` defaults to
          # `:read` per the catalog's derived manifest — only the
          # state-mutating tools override.
          :read
        end

      %{
        name:    mod.name(),
        kind:    kind,
        purpose: short_purpose(mod.description())
      }
    end)
  end

  defp manifest_for_connector(slug, user_id, session_id) do
    dispatcher_entries =
      slug
      |> DmhAi.Connectors.Manifest.list_for_slug()
      |> Enum.map(&connector_spec_to_manifest_entry(slug, &1))

    if dispatcher_entries == [] do
      mcp_entries_for_slug(slug, user_id, session_id)
    else
      dispatcher_entries
    end
  end

  defp connector_spec_to_manifest_entry(slug, %{function_name: fn_name, args: args, returns: returns, permission: perm}) do
    %{
      name:    slug <> "." <> fn_name,
      kind:    (if perm == :write, do: :write, else: :read),
      purpose: format_connector_purpose(args, returns)
    }
  end

  defp connector_spec_to_manifest_entry(slug, _), do: %{name: slug, kind: :read, purpose: ""}

  defp format_connector_purpose(args, returns) when is_map(args) and is_map(returns) do
    "args(" <> format_args(args) <> ") → returns(" <> format_returns(returns) <> ")"
  end

  defp format_connector_purpose(_, _), do: ""

  defp format_args(args) do
    args
    |> Enum.map(fn {name, meta} ->
      req = if Map.get(meta, :required) == true, do: "", else: "?"
      type = meta |> Map.get(:type) |> to_string()

      default =
        case Map.get(meta, :provenance) do
          %{kind: :literal_default, value: v} -> "=#{inspect(v)}"
          _                                    -> ""
        end

      "#{name}#{req}:#{type}#{default}"
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp format_returns(returns) do
    returns
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp mcp_entries_for_slug(slug, user_id, session_id) when is_binary(user_id) and is_binary(session_id) do
    MCP.Registry.tools_for_session(user_id, session_id)
    |> Enum.filter(fn t -> String.starts_with?(t.name, slug <> ".") end)
    |> Enum.map(fn t ->
      %{
        name:    t.name,
        kind:    :read,
        purpose: short_purpose(t.description)
      }
    end)
  end

  defp mcp_entries_for_slug(_, _, _), do: []

  defp short_purpose(nil), do: ""

  defp short_purpose(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.split(~r/\.\s+|\n\n/, parts: 2)
    |> List.first()
    |> String.slice(0, 200)
  end

  @doc """
  Gate a tool-call dispatch against the current active profile set.

  Returns:
    * `:ok` — the tool is in `:core` or in one of the active
      profiles; the dispatcher should proceed normally.
    * `{:needs_profile, profile_string}` — the tool is registered
      under a profile the chain hasn't activated. The dispatcher
      should return a corrective error naming `profile_string` so
      the model retries via `activate_profile`.
    * `:unknown` — the tool name isn't in ANY profile (likely a
      hallucinated / typo'd name). The dispatcher's existing
      "Unknown tool" path handles it.

  Connector verbs use the `<slug>.<function>` shape; everything
  else is a built-in name. Both shapes resolve through this
  single entry point.
  """
  @spec gate(String.t(), [String.t()]) ::
          :ok | {:needs_profile, String.t()} | :unknown
  def gate(tool_name, active_profiles) when is_binary(tool_name) and is_list(active_profiles) do
    cond do
      core_member?(tool_name) ->
        :ok

      profile = built_in_profile(tool_name) ->
        if Atom.to_string(profile) in active_profiles,
          do: :ok,
          else: {:needs_profile, Atom.to_string(profile)}

      connector_name?(tool_name) ->
        [slug | _] = String.split(tool_name, ".", parts: 2)
        connector_profile = "connector:" <> slug

        if connector_profile in active_profiles,
          do: :ok,
          else: {:needs_profile, connector_profile}

      true ->
        :unknown
    end
  end

  defp core_member?(name) do
    Enum.any?(@core, fn mod -> mod.name() == name end)
  end

  defp built_in_profile(name) do
    cond do
      Enum.any?(@auth, fn mod -> mod.name() == name end) -> :auth
      Enum.any?(@workflows, fn mod -> mod.name() == name end) -> :workflows
      true -> nil
    end
  end

  defp connector_name?(name) do
    String.contains?(name, ".")
  end
end
