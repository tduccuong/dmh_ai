# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Kb.SchemaInit do
  @moduledoc """
  Supervisor child that creates the facts.db / memos.db schemas as soon as
  `DmhAi.FactsRepo` and `DmhAi.MemosRepo` are up. Placed AFTER both repos in
  the `:rest_for_one` tree so the tables exist before anything queries them.
  """
  use GenServer, restart: :transient

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    DmhAi.Kb.Schema.create_all(DmhAi.FactsRepo, "facts")
    DmhAi.Kb.Schema.create_all(DmhAi.MemosRepo, "memos")

    # Fact-extraction watermark (last processed user-message ts per user).
    DmhAi.FactsRepo.query!(
      "CREATE TABLE IF NOT EXISTS facts_watermark (user_id TEXT PRIMARY KEY, last_ts INTEGER NOT NULL)",
      []
    )

    :ignore
  end
end
