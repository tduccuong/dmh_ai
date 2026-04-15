# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Schemas.BlockedDomain do
  use Ecto.Schema

  @primary_key {:domain, :string, autogenerate: false}
  schema "blocked_domains" do
    field :reason, :string
    field :timeout_count, :integer, default: 0
    field :added_at, :integer
  end
end
