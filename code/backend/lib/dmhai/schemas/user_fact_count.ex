defmodule Dmhai.Schemas.UserFactCount do
  use Ecto.Schema

  @primary_key false
  schema "user_fact_counts" do
    field :user_id, :string, primary_key: true
    field :topic, :string, primary_key: true
    field :count, :integer, default: 1
  end
end
