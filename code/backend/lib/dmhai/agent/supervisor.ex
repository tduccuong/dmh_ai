# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Supervisor do
  @moduledoc """
  DynamicSupervisor that owns all per-user UserAgent processes.
  UserAgents are started lazily on first command and shut themselves down
  after 30 minutes of idle.
  """
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Returns the pid of the UserAgent for `user_id`, starting one if needed.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(user_id) do
    case Registry.lookup(Dmhai.Agent.Registry, user_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = {Dmhai.Agent.UserAgent, user_id}

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end
end
