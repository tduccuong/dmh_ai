# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler do
  @moduledoc """
  FunctionSpec map for the Microsoft 365 connector consumed by the
  generic `Connectors.MCPServer`. Each verb is declared in one of
  the per-vendor-surface sub-modules — Mail, Cal, Files, Teams,
  Todo, Excel, OneNote, Contacts, Users — and this façade merges
  them into the single map the dispatcher reads.

  Vendor anchors per function match `Connectors.M365`'s manifest
  comments — same `# vendor: …` URL grounding.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec

  alias __MODULE__.{
    Mail,
    Cal,
    Files,
    Teams,
    Todo,
    Excel,
    OneNote,
    Contacts,
    Users
  }

  @doc """
  Connector handler entry consumed by
  `Connectors.MCPServer.Registry.put/1` at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "m365", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{}
    |> Map.merge(Mail.function_specs())
    |> Map.merge(Cal.function_specs())
    |> Map.merge(Files.function_specs())
    |> Map.merge(Teams.function_specs())
    |> Map.merge(Todo.function_specs())
    |> Map.merge(Excel.function_specs())
    |> Map.merge(OneNote.function_specs())
    |> Map.merge(Contacts.function_specs())
    |> Map.merge(Users.function_specs())
  end
end
