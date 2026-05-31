# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Sheets do
  @moduledoc """
  Google Sheets surface — `sheets.read_range`, `sheets.append_row`,
  `sheets.update_range`.
  """

  alias DmhAi.Connectors.MCPServer.{RestBridge, FunctionSpec}
  alias DmhAi.Connectors.GoogleWorkspace.MCPHandler.Helpers

  @sheets_base "https://sheets.googleapis.com/v4"

  # A1-notation Sheets ranges accept sheet-name qualifiers
  # (`Sheet1!A1:B2`), apostrophe-quoted sheet names with periods /
  # spaces removed (we don't accept spaces — the model can rename
  # the sheet), and bare cell / column refs. The charset stays
  # conservative — no SQL / DSL meta characters.
  @sheets_range_re ~r/^[A-Za-z0-9_!:'.\-]+$/

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "sheets.read_range" => %FunctionSpec{
        handler: &sheets_read_range/2,
        doc:     "Read a cell range from a Google Sheet (A1 notation, e.g. 'Sheet1!A1:C50')."
      },
      "sheets.append_row" => %FunctionSpec{
        handler: &sheets_append_row/2,
        doc:     "Append a row to a Google Sheet at the given range."
      },
      "sheets.update_range" => %FunctionSpec{
        handler: &sheets_update_range/2,
        doc:     "Overwrite a cell range in a Google Sheet with a 2-D values array."
      }
    }
  end

  # ─── sheets.read_range — values.get with URL-encoded range ────────────

  # vendor: GET /v4/spreadsheets/{spreadsheetId}/values/{range}
  defp sheets_read_range(args, ctx) do
    spreadsheet_id = args["spreadsheet_id"]
    range          = args["range"]
    url = "#{@sheets_base}/spreadsheets/#{URI.encode(spreadsheet_id)}/values/#{URI.encode(range)}"

    case RestBridge.raw_request(:get, Helpers.with_bearer([url: url], ctx)) do
      {:ok, 200, body} ->
        {:ok, %{
          "spreadsheet_id" => spreadsheet_id,
          "range"          => body["range"] || range,
          "values"         => Map.get(body, "values", [])
        }}

      {:ok, _status, _body} ->
        {:error, :upstream_other}

      {:error, _} = err ->
        err
    end
  end

  # ─── sheets.append_row — values.append, single-row wrap ───────────────

  # vendor: POST /sheets/v4/spreadsheets/{id}/values/{range}:append
  # docs:   https://developers.google.com/sheets/api/reference/rest/v4/spreadsheets.values/append
  defp sheets_append_row(args, ctx) do
    spreadsheet_id = Helpers.safe_path_id(args["spreadsheet_id"])
    range          = safe_sheet_range(args["range"])
    values         = args["values"] || []

    url =
      "#{@sheets_base}/spreadsheets/#{spreadsheet_id}/values/" <>
      "#{URI.encode(range)}:append"

    opts = [
      url:    url,
      params: [{"valueInputOption", "USER_ENTERED"}],
      json:   %{"values" => [values]}
    ]

    case RestBridge.raw_request(:post, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        updated = get_in(body, ["updates", "updatedRange"]) || range
        {:ok, %{"updated_range" => updated}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ─── sheets.update_range — values.update, 2-D values ──────────────────

  # vendor: PUT /sheets/v4/spreadsheets/{id}/values/{range}
  # docs:   https://developers.google.com/sheets/api/reference/rest/v4/spreadsheets.values/update
  defp sheets_update_range(args, ctx) do
    spreadsheet_id = Helpers.safe_path_id(args["spreadsheet_id"])
    range          = safe_sheet_range(args["range"])
    values         = args["values"] || []

    url = "#{@sheets_base}/spreadsheets/#{spreadsheet_id}/values/#{URI.encode(range)}"

    opts = [
      url:    url,
      params: [{"valueInputOption", "USER_ENTERED"}],
      json:   %{"values" => values}
    ]

    case RestBridge.raw_request(:put, Helpers.with_bearer(opts, ctx)) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        updated = body["updatedRange"] || range
        {:ok, %{"updated_range" => updated}}

      {:ok, status, body} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # Sheet-range whitelist — only used by the Sheets surface so it
  # stays local rather than living in shared Helpers.
  defp safe_sheet_range(range) do
    str = to_string(range)

    if Regex.match?(@sheets_range_re, str) do
      str
    else
      raise ArgumentError, "invalid sheets A1 range: #{inspect(range)}"
    end
  end
end
