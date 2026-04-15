# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

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
