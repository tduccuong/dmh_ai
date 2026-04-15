# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Schemas.AuthToken do
  use Ecto.Schema

  @primary_key {:token, :string, autogenerate: false}
  schema "auth_tokens" do
    field :user_id, :string
    field :created_at, :integer
  end
end
