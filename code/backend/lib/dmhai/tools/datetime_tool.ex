# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.DatetimeTool do
  @behaviour Dmhai.Tools.Behaviour

  @impl true
  def name, do: "datetime"

  @impl true
  def description,
    do:
      "Get the current date and time. Optionally specify an IANA timezone " <>
        "(e.g. 'America/New_York', 'Asia/Ho_Chi_Minh', 'Europe/Berlin'). Defaults to UTC."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          timezone: %{
            type: "string",
            description:
              "IANA timezone name, e.g. 'America/New_York', 'Asia/Ho_Chi_Minh', 'Europe/Paris'. " <>
                "Defaults to UTC if omitted or unknown."
          }
        },
        required: []
      }
    }
  end

  @impl true
  def execute(args, _context) do
    tz = Map.get(args, "timezone", "UTC")

    utc_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {local_str, valid_tz} =
      case System.cmd("date", ["+%Y-%m-%dT%H:%M:%S %Z (UTC%z)"],
             env: [{"TZ", tz}],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {String.trim(output), true}
        _ -> {utc_iso, false}
      end

    result = %{utc: utc_iso, local: local_str, timezone: if(valid_tz, do: tz, else: "UTC")}

    result =
      if valid_tz,
        do: result,
        else: Map.put(result, :note, "Unknown timezone '#{tz}', returned UTC")

    {:ok, result}
  end
end
