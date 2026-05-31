# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.MCPHandler.Excel do
  @moduledoc """
  Excel workbook surface — `excel.read_range`, `excel.update_range`.
  Range argument is validated against A1 notation before the URL is
  built so an injected fragment can't slip into the path.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.M365.MCPHandler.Helpers

  @graph_base Helpers.graph_base()

  # Excel range in A1 notation (single cell or range, e.g. `A1`, `B2:D10`).
  @excel_range_re ~r/^[A-Z]+\d+(:[A-Z]+\d+)?$/

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "excel.read_range" => %FunctionSpec{
        handler: &excel_read_range/2,
        doc:     "Read a cell range from an Excel workbook in OneDrive (A1 notation)."
      },
      "excel.update_range" => %FunctionSpec{
        handler: &excel_update_range/2,
        doc:     "Write a 2D values array into an Excel worksheet range (A1 notation)."
      }
    }
  end

  # ─── excel.read_range — workbook /worksheets/{sheet}/range ────────────

  defp excel_read_range(args, ctx) do
    workbook_id = args["workbook_id"]
    sheet       = args["worksheet"]
    range       = args["range"]

    url =
      "#{@graph_base}/drive/items/#{URI.encode(workbook_id)}" <>
        "/workbook/worksheets/#{URI.encode(sheet)}/range(address='#{URI.encode(range)}')"

    case RestBridge.raw_request(:get, Helpers.with_bearer([url: url], ctx)) do
      {:ok, 200, body} ->
        {:ok, %{
          "workbook_id" => workbook_id,
          "worksheet"   => sheet,
          "range"       => body["address"] || range,
          "values"      => Map.get(body, "values", [])
        }}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── excel.update_range — PATCH workbook range ────────────────────────
  # vendor: PATCH /v1.0/me/drive/items/{id}/workbook/worksheets/{sheet}/range(address='A1:C5')
  # docs:   https://learn.microsoft.com/graph/api/range-update
  # `range` is validated against A1 notation before the URL is built.

  defp excel_update_range(args, ctx) do
    file_id   = Helpers.safe_path_id(args["file_id"])
    worksheet = Helpers.safe_path_id(args["worksheet"])
    range     = validate_excel_range(args["range"])
    values    = args["values"]

    url =
      "#{@graph_base}/drive/items/#{file_id}" <>
        "/workbook/worksheets/#{worksheet}/range(address='#{range}')"

    case RestBridge.raw_request(:patch, Helpers.with_bearer([url: url, json: %{"values" => values}], ctx)) do
      {:ok, status, _body} when status in 200..299 ->
        {:ok, %{"ok" => true}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp validate_excel_range(range) do
    str = to_string(range)

    if Regex.match?(@excel_range_re, str) do
      str
    else
      raise ArgumentError, "invalid Excel range (A1 notation expected): #{inspect(range)}"
    end
  end
end
