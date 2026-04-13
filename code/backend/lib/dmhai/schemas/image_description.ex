defmodule Dmhai.Schemas.ImageDescription do
  use Ecto.Schema

  @primary_key false
  schema "image_descriptions" do
    field :session_id, :string, primary_key: true
    field :file_id, :string, primary_key: true
    field :name, :string
    field :description, :string
    field :created_at, :integer
  end
end
