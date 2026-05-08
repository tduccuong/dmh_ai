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
  BEFORE any child that queries the DB (`DmhAi.Agent.TaskRuntime`,
  etc.), under a `:rest_for_one` strategy so a Repo restart re-runs
  schema init before downstream children come back.

  Without this, on a fresh install the DB is empty when
  `TaskRuntime.handle_info(:rehydrate, …)` fires (~500ms after init),
  the rehydrate query crashes on `no such table: tasks`, the
  supervisor restarts TaskRuntime, it crashes again the same way,
  exceeds default `max_restarts` (3 in 5s), tears down the whole
  supervision tree (Repo with it), and the post-`Supervisor.start_link`
  call to `DB.Init.run()` fails with `could not lookup Ecto repo
  DmhAi.Repo because it was not started`. Result: master restart-loops
  forever on first boot. Existing installs don't see the bug because
  `chat.db` carries the schema across boots.
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
