# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Schemas.UserFactCount do
  use Ecto.Schema

  @primary_key false
  schema "user_fact_counts" do
    field :user_id, :string, primary_key: true
    field :topic, :string, primary_key: true
    field :count, :integer, default: 1
  end
end
