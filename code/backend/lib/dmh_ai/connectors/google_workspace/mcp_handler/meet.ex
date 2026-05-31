# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Meet do
  @moduledoc """
  Google Meet surface — `meet.create_meeting`.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec

  @meet_base "https://meet.googleapis.com/v2"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "meet.create_meeting" => %FunctionSpec{
        method:  :post,
        url:     "#{@meet_base}/spaces",
        # Empty body — Meet's spaces.create takes no request args
        # for the basic case. The shim returns the join URL +
        # meeting code as a flat shape the model can paste into
        # its reply verbatim.
        request: fn _args, _ctx -> [json: %{}] end,
        response: fn s, body when s in 200..299 ->
                    {:ok, %{
                      "join_url"     => body["meetingUri"],
                      "meeting_code" => body["meetingCode"],
                      "space_name"   => body["name"]
                    }}
                  end,
        doc: "Create a Google Meet space and return the join URL."
      }
    }
  end
end
