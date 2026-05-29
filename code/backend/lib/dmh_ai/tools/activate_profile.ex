# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ActivateProfile do
  @moduledoc """
  Meta-tool — widen the chain's active tool surface by loading one
  or more profiles. Lives in `:core` so it's always callable.

  Profiles persist in `session.context.active_profiles` for the
  remainder of the chain; the runtime resets them to `[]` when
  the chain ends (assistant text turn with no tool_call). See
  `arch_wiki/dmh_ai/architecture.md` §Execution tools / §Tool
  profiles.

  The tool result lists which tools the model can now call. The
  NEXT LLM turn's request body is built with the expanded
  catalogue; this turn's response is just the activation ack.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.SessionContext
  alias DmhAi.MCP
  alias DmhAi.Tools.Profiles

  @impl true
  def name, do: "activate_profile"

  @impl true
  def description do
    """
    Pre-load one or more tool profiles to see their full tool catalog before you commit to a call. Optional — calling a tool directly auto-loads its profile, so use this only when you want to inspect what a surface offers up front. Activated profiles persist for the rest of the chain and reset when it ends.

    Valid profile names:
    - `auth` — credential / connector setup: connecting, authorizing, saving creds, ssh-key provisioning.
    - `workflows` — building, running, editing, or arming a repeatable automation.
    - `connector:<slug>` — a connector's typed tools, substituting the slug as it appears in `<authorized_services>`.

    Returns `{activated, manifest}` — the profiles added plus a manifest of every tool each makes callable, with arg shape and return keys. Compose calls / IR against EXACTLY the names in the manifest. Activating an already-active profile is idempotent; unknown names return the valid set so you can retry.
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          profiles: %{
            type: "array",
            items: %{type: "string"},
            description: "List of profile names to add to the active set: `auth`, `workflows`, or `connector:<slug>` (slug from `<authorized_services>`). `core` is implicit — passing it is a no-op."
          }
        },
        required: ["profiles"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id    = ctx[:user_id]    || ctx["user_id"]
    session_id = ctx[:session_id] || ctx["session_id"]
    requested  = Map.get(args, "profiles", [])

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "activate_profile: no user_id in context"}

      not is_binary(session_id) or session_id == "" ->
        {:error, "activate_profile: no session_id in context"}

      not is_list(requested) ->
        {:error, "activate_profile: `profiles` must be a list of strings, got #{inspect(requested)}"}

      requested == [] ->
        {:error, "activate_profile: `profiles` list is empty — pass at least one profile name."}

      true ->
        do_activate(user_id, session_id, requested)
    end
  end

  defp do_activate(user_id, session_id, requested) do
    available_slugs = MCP.Registry.attached_aliases(session_id)

    case Profiles.validate(requested, available_slugs) do
      {:ok, normalised} ->
        # Persist the union of existing + newly-requested profile
        # strings. We store the model-side string names (what the
        # validator accepted) so reads / writes are symmetric.
        already_active = SessionContext.active_profiles(session_id)
        new_active = Enum.uniq(already_active ++ requested)
        SessionContext.set_active_profiles(session_id, new_active)

        manifest = Profiles.build_manifest(normalised, user_id, session_id)

        {:ok, %{
          activated: requested,
          manifest:  manifest,
          note:      "AUTHORITATIVE catalog above — `manifest` lists every tool each profile makes callable, with arg + return shape. Compose IR / tool calls only against names that appear here. If the user's request needs a tool that isn't in the manifest for any active profile, this deployment does not expose that capability — tell the user plainly and ask whether to use a different route (raw `run_script` + curl) or a different connector. `inspect_function` remains for deep details (provenance, error classes, scopes) when composing a workflow step, not for checking whether a tool exists."
        }}

      {:error, %{unknown: unknown, valid: valid}} ->
        {:error,
         "activate_profile: unknown profile name(s) #{inspect(unknown)}. " <>
           "Valid names for THIS session: #{inspect(valid)}. " <>
           "Connector profiles are only valid for slugs visible in <authorized_services>; " <>
           "if the slug you need isn't attached, call `connect_mcp(slug: \"<slug>\")` first."}
    end
  end

end
