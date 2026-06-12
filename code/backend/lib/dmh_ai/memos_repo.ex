# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.MemosRepo do
  @moduledoc """
  Dedicated SQLite database (`memos.db`) for `/memo` entries. Its own repo
  so the `spellfix1` extension loads per-connection.
  See arch_wiki/dmh_ai/facts_memos.md.
  """
  use Ecto.Repo, otp_app: :dmh_ai, adapter: Ecto.Adapters.SQLite3
end
