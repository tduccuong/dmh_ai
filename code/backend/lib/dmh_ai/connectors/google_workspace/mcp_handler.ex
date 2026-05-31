# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler do
  @moduledoc """
  Function-spec map for the Google Workspace connector consumed by the
  generic `Connectors.MCPServer`. Each verb is declared in one of the
  per-vendor-surface sub-modules — Gmail, Gcal, Drive, Sheets, Tasks,
  Docs, Meet, Contacts, Directory — and this façade merges them into
  the single map the dispatcher reads.

  Vendor anchors per function match `Connectors.GoogleWorkspace`'s
  manifest comments — same `# vendor: …` URL grounding.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec

  alias __MODULE__.{
    Gmail,
    Gcal,
    Drive,
    Sheets,
    Tasks,
    Docs,
    Meet,
    Contacts,
    Directory
  }

  @doc """
  Connector handler entry consumed by
  `Connectors.MCPServer.Registry.put/1` at boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "google_workspace", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{}
    |> Map.merge(Gmail.function_specs())
    |> Map.merge(Gcal.function_specs())
    |> Map.merge(Drive.function_specs())
    |> Map.merge(Sheets.function_specs())
    |> Map.merge(Tasks.function_specs())
    |> Map.merge(Docs.function_specs())
    |> Map.merge(Meet.function_specs())
    |> Map.merge(Contacts.function_specs())
    |> Map.merge(Directory.function_specs())
  end
end
