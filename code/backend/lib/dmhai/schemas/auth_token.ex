defmodule Dmhai.Schemas.AuthToken do
  use Ecto.Schema

  @primary_key {:token, :string, autogenerate: false}
  schema "auth_tokens" do
    field :user_id, :string
    field :created_at, :integer
  end
end
