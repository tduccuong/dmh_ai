# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.SchemaInit do
  @moduledoc """
  Supervisor child that synchronously creates the DB schema as soon as
  `DmhAi.Repo` is up. Runs once per BEAM boot via `init/1`, then
  returns `:ignore` so the supervisor moves on to the next child.

  Placed in the supervision tree IMMEDIATELY AFTER `DmhAi.Repo` and
  BEFORE any child that queries the DB, under a `:rest_for_one`
  strategy so a Repo restart re-runs schema init before downstream
  children come back.
  """
  use GenServer, restart: :transient

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    DmhAi.DB.Init.run()
    DmhAi.Permissions.Migration.run()
    :ignore
  end
end
