# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Orgs do
  @moduledoc """
  Helpers for org-scoped lookups (Primitive 0.1).

  Every scoped artefact carries `org_id NOT NULL` referencing
  `organizations.id`. Code that ingests, queries, or scopes per-org
  often only has a `user_id` in hand — `for_user/1` resolves to the
  user's `org_id`, falling back to the default org slug if the user
  row is missing or pre-migration.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Resolve the org_id for a given user. Returns the user's `org_id`
  when set; otherwise the install's default org slug.
  """
  @spec for_user(String.t() | nil) :: String.t()
  def for_user(nil), do: default_id()

  def for_user(user_id) when is_binary(user_id) do
    case query!(Repo, "SELECT org_id FROM users WHERE id=?", [user_id]).rows do
      [[org_id]] when is_binary(org_id) and org_id != "" -> org_id
      _ -> default_id()
    end
  rescue
    _ -> default_id()
  end

  @doc "The install's default org slug. Same as Constants.default_org_id/0."
  @spec default_id() :: String.t()
  def default_id, do: DmhAi.Constants.default_org_id()
end
