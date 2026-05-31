# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.ProfileResolution do
  @moduledoc """
  Tool-profile lifecycle: chain-end reset, per-turn catalog injection,
  and dependency resolution (the model calling a tool from a
  known-but-inactive profile auto-activates that profile).

  See `arch_wiki/dmh_ai/architecture.md` §Tool profiles / §Auto-deactivate
  at chain end.
  """

  @doc """
  Chain-end reset: any profiles the model activated during this chain
  are dropped, so the next chain starts at `:core`-only.
  """
  def reset_active_profiles(%{session_id: session_id}) when is_binary(session_id) do
    DmhAi.Agent.SessionContext.set_active_profiles(session_id, [])
  end
  def reset_active_profiles(_), do: :ok

  @doc """
  Insert the active-profile catalog as a system-role message right
  after the base system prompt (index 0). Transient — operates on
  the OUTGOING message list only; the persisted `session.messages`
  never carries it. No active profiles → messages unchanged. The
  block is rebuilt each turn from the live active set, so it can't
  leak across chains (chain end resets the active set to []).
  """
  def inject_active_catalog(messages, active_profiles, _ctx) do
    case DmhAi.Tools.Profiles.format_catalog_block(active_profiles) do
      nil ->
        messages

      block ->
        catalog_msg = %{role: "system", content: block}

        case messages do
          [first | rest] -> [first, catalog_msg | rest]
          [] -> [catalog_msg]
        end
    end
  end

  @doc """
  Auto-activate the profile that owns `tool_name` when it isn't
  already active. The model expressing intent to call a tool IS the
  signal it needs that tool's profile, so the runtime loads it rather
  than rejecting the call. Persists to session context (so the schema
  ships next turn) and returns ctx with `:active_profiles` updated for
  the rest of THIS turn's gates. Tools in `:core` (or unknown names)
  are no-ops.

  Returns `{updated_ctx, profile_or_nil}` — caller uses the second
  element to decide whether to splice a manifest into the result.
  """
  def resolve_profile_dependency(tool_name, ctx) do
    active = Map.get(ctx, :active_profiles, [])

    case DmhAi.Tools.Profiles.gate(tool_name, active) do
      {:needs_profile, profile} ->
        new_active = Enum.uniq(active ++ [profile])

        if session_id = Map.get(ctx, :session_id) do
          DmhAi.Agent.SessionContext.set_active_profiles(session_id, new_active)
        end

        DmhAi.SysLog.log("[ASSISTANT] auto-activated profile=#{profile} for tool=#{tool_name}")
        {Map.put(ctx, :active_profiles, new_active), profile}

      _ ->
        {ctx, nil}
    end
  end

  @doc """
  Mirror what `activate_profile` / `connect_mcp` already return: when
  the runtime auto-activates a profile to satisfy a direct tool call,
  inject that profile's manifest into the {:ok, result} envelope so
  the model immediately sees the other tools it just unlocked.
  Only augments map results; non-map results (strings, lists) pass
  through untouched.
  """
  def augment_with_profile_manifest(result, nil, _ctx), do: result

  def augment_with_profile_manifest(result, profile, ctx) when is_map(result) do
    manifest = DmhAi.Tools.Profiles.build_manifest([profile], ctx.user_id, ctx.session_id)

    result
    |> Map.put_new("profile_activated", profile)
    |> Map.put_new("manifest", manifest)
    |> Map.put_new(
      "note",
      "Profile `" <> profile <> "` was auto-activated by this call; `manifest` lists every tool " <>
        "it now makes callable. Compose subsequent calls / IR against those names."
    )
  end

  def augment_with_profile_manifest(result, _profile, _ctx), do: result
end
