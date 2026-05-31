# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.Settings do
  @moduledoc """
  Key/value reads against the `settings` table.

  Used by `Data.Sessions` to read and write the per-user mode
  preference + per-mode last-active session id.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  def read_setting(key) do
    case query!(Repo, "SELECT value FROM settings WHERE key=?", [key]).rows do
      [[v] | _] -> v
      _ -> nil
    end
  end

  def write_setting(key, value) do
    query!(Repo, "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [key, value])
  end
end
