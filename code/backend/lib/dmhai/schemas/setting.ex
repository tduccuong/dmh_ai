defmodule Dmhai.Schemas.Setting do
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :string
  end
end
