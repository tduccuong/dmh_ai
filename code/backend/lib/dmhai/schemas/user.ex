defmodule Dmhai.Schemas.User do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "users" do
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :role, :string, default: "user"
    field :created_at, :integer
    field :password_changed, :integer, default: 0
    field :deleted, :integer, default: 0
    field :profile, :string, default: ""
  end
end
