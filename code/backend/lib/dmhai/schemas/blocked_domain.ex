defmodule Dmhai.Schemas.BlockedDomain do
  use Ecto.Schema

  @primary_key {:domain, :string, autogenerate: false}
  schema "blocked_domains" do
    field :reason, :string
    field :timeout_count, :integer, default: 0
    field :added_at, :integer
  end
end
