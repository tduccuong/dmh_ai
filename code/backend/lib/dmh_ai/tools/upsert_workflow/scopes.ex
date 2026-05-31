# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Scopes do
  @moduledoc """
  L3 — Compile-time scope gate. See
  `arch_wiki/dmh_ai/sme/layer-W.md` §Runtime self-sufficiency / L3.

  Unions the OAuth scopes every step's function requires; compares
  against the user's current grant per slug. Missing scopes means
  the workflow would silently `needs_auth` on its first armed fire
  — reject the save and tell the user to reconnect.
  """

  alias DmhAi.Auth.Credentials
  alias DmhAi.OAuth.Catalog, as: OAuthCatalog
  alias DmhAi.Tools.UpsertWorkflow.{Functions, RequiredArgs, Synthetics}

  @doc """
  Walk every step node, union the required scopes per slug,
  compare against the owner's granted scopes, reject if any slug
  has unfulfilled scope requirements.
  """
  @spec check_scopes(map(), String.t() | nil) :: :ok | {:error, String.t()}
  def check_scopes(ir, owner_id) when is_binary(owner_id) do
    requirements =
      ir
      |> Map.get("nodes", [])
      |> Enum.filter(&Functions.is_step_node?/1)
      |> Enum.reject(fn n -> n["function"] in Synthetics.list() end)
      |> Enum.reduce(%{}, fn n, acc ->
        case RequiredArgs.function_spec(n["function"]) do
          %{scopes_required: scopes} when is_list(scopes) and scopes != [] ->
            slug = n["function"] |> String.split(".", parts: 2) |> List.first()
            Map.update(acc, slug, MapSet.new(scopes), fn s ->
              MapSet.union(s, MapSet.new(scopes))
            end)

          _ ->
            acc
        end
      end)

    missing_by_slug =
      Enum.reduce(requirements, %{}, fn {slug, required}, acc ->
        granted = granted_scopes_for(owner_id, slug)
        missing = MapSet.difference(required, granted) |> MapSet.to_list()
        if missing == [], do: acc, else: Map.put(acc, slug, missing)
      end)

    case map_size(missing_by_slug) do
      0 ->
        :ok

      _ ->
        details =
          Enum.map_join(missing_by_slug, "; ", fn {slug, missing} ->
            "`#{slug}` needs #{inspect(missing)}"
          end)

        {:error,
         "upsert_workflow: workflow needs OAuth scopes the user hasn't granted yet — #{details}. " <>
           "Tell the user to click **My Services → Reconnect** for each affected service so the " <>
           "next consent grants the missing scopes. The workflow will save once scopes are present."}
    end
  end

  def check_scopes(_ir, _owner), do: :ok

  @doc """
  Resolve the MapSet of scopes granted to `owner_id` for the named
  connector `slug`. Reads from the slug-keyed credential row
  (`oauth:<slug>`) — see `finalize_oauth_service` /
  `finalize_connector_oauth` writers in `Handlers.OAuthCallback`.
  Returns an empty MapSet when the catalog doesn't know the slug
  or the user hasn't granted anything yet.
  """
  @spec granted_scopes_for(String.t(), String.t()) :: MapSet.t()
  def granted_scopes_for(owner_id, slug) when is_binary(slug) do
    # Credential targets are slug-keyed (`oauth:<slug>`). The
    # catalog row is consulted only to confirm the slug is a known
    # service; `host_match` rides along in the cred's payload but
    # is no longer a primary key.
    case OAuthCatalog.get_by_slug(slug) do
      %{} ->
        owner_id
        |> Credentials.lookup_all("oauth:" <> slug)
        |> Enum.flat_map(fn cred ->
          case Map.get(cred, :payload, %{}) do
            %{"scope" => s} when is_binary(s) -> String.split(s, " ", trim: true)
            %{"scopes" => list} when is_list(list) -> list
            _ -> []
          end
        end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end
end
