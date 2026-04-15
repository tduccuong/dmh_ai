defmodule Dmhai.Schemas.Session do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "sessions" do
    field :name, :string
    field :messages, :string, default: "[]"
    field :context, :string
    field :created_at, :integer
    field :updated_at, :integer
    field :user_id, :string, default: ""
  end
end
