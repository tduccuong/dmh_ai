# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

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
