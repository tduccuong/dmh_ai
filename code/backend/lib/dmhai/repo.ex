# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Repo do
  use Ecto.Repo,
    otp_app: :dmhai,
    adapter: Ecto.Adapters.SQLite3
end
