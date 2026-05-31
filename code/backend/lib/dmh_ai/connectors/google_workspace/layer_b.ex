# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.LayerB do
  @moduledoc """
  Layer B for Google Workspace — per-user vendor metadata sweep +
  cached-property reader. Lives in its own module because the parent
  `GoogleWorkspace` connector is already at the file-size ceiling and
  the parent re-exports both callbacks via `defdelegate`.

  Three cache rows go in per user, one per Google sub-product whose
  identifiers the manifest's args reference directly:

    * `calendars` — the user's calendar list (primary + secondary +
      subscribed) as a single `calendar_id` property whose options
      enumerate the available ids. Backs `gcal.*` functions whose
      `calendar_id` arg defaults to `primary` but can target any
      calendar the user has access to.
    * `gmail.labels` — the user's Gmail label set (system labels like
      INBOX/SENT/DRAFT plus user-defined labels) as a single
      `label_id` property. Backs `gmail.search` (label filter) and
      `gmail.label` (add/remove label ids on a message).
    * `drives` — the user's shared drives (Team Drives) as a single
      `drive_id` property. Backs `drive.*` functions that target a
      shared drive instead of My Drive. The `?pageSize=100` cap is
      intentional: SME tenants almost never exceed 100 shared drives,
      and a single page keeps the sweep simple; if a deployment ever
      needs more, walk `nextPageToken`.

  `inspect_property/3` resolves by exact-name match — `calendar_id`
  against the `calendars` cache row, `label_id` against `gmail.labels`,
  `drive_id` against `drives`. The arg names in the GW manifest already
  match these property names so no prefix-stripping is needed.

  For Gmail's plural `label_ids` (list args on `gmail.search` and
  `gmail.label`), the model validates one element at a time by passing
  `label_id` as the path; the same cache row answers the lookup either
  way.
  """

  @behaviour DmhAi.Connectors.Discoverable

  # Map a function bare-name to the cache row whose enum is the source
  # of truth for that function's identifier arg. The `inspect_property/3`
  # callback uses this to route a property lookup at the cached
  # metadata row produced by `discover_metadata/1`.
  @function_to_cache %{
    "gcal.list_events"     => "calendars",
    "gcal.create_event"    => "calendars",
    "gcal.update_event"    => "calendars",
    "gcal.delete_event"    => "calendars",
    "gcal.find_free_slots" => "calendars",
    "gmail.search"         => "gmail.labels",
    "gmail.label"          => "gmail.labels",
    "drive.list"           => "drives",
    "drive.upload"         => "drives",
    "drive.create_folder"  => "drives",
    "drive.download"       => "drives"
  }

  # Per-user metadata sweep. Pulls calendars + Gmail labels + shared
  # drives in one go using the user's `oauth:google_workspace`
  # credential and returns the three cache rows the
  # `connector_vendor_metadata` table expects. Each step halts the
  # reduce on a non-200 so the runner records the failure against the
  # whole sweep — partial caches are worse than no cache.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "oauth:google_workspace") do
      [%{payload: %{"access_token" => token}} | _] when is_binary(token) ->
        sweep_layer_b(token)

      _ ->
        {:error, :no_google_workspace_credential}
    end
  end

  # Layer B reader. Consult the metadata cache populated by
  # `discover_metadata/1`, locate the matching property by exact name,
  # return its type, label, and vendor's option list as the enum.
  #
  # Returns `:not_supported` when:
  #   * the function name doesn't map to a known cache row
  #   * the user hasn't run Discover Metadata yet (cache empty)
  #   * the requested property isn't in the cached schema
  @spec inspect_property(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_supported}
  def inspect_property(function_name, path, ctx) do
    with cache_path when is_binary(cache_path) <- Map.get(@function_to_cache, function_name),
         %{schema: %{"properties" => props}} when is_list(props) <-
           Enum.find(ctx[:vendor_metadata] || [], fn r -> r.path == cache_path end),
         %{} = prop <- Enum.find(props, fn p -> p["name"] == path end) do
      {:ok,
       %{
         type:        prop["type"],
         enum:        extract_enum(prop),
         description: prop["label"],
         source:      :vendor_metadata
       }}
    else
      _ -> {:error, :not_supported}
    end
  end

  defp extract_enum(%{"options" => options}) when is_list(options) and options != [] do
    options
    |> Enum.map(fn o -> o["value"] end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_enum(_), do: nil

  # Three-step reduce, one HTTP call per Google sub-product. Each
  # vendor base URL is its own host (Calendar + Drive on
  # `www.googleapis.com`, Gmail on `gmail.googleapis.com`) so we don't
  # share a base; the headers (Bearer auth + JSON accept) are the only
  # repeated piece.
  defp sweep_layer_b(token) do
    headers = [{"authorization", "Bearer " <> token}, {"accept", "application/json"}]

    steps = [
      {"calendars",
       "https://www.googleapis.com/calendar/v3/users/me/calendarList",
       &build_calendars_row/1},
      {"gmail.labels",
       "https://gmail.googleapis.com/gmail/v1/users/me/labels",
       &build_labels_row/1},
      # `pageSize=100` is the vendor's per-request cap. SME tenants
      # almost never exceed 100 shared drives; one page is enough. If
      # a deployment ever needs more, walk `nextPageToken`.
      {"drives",
       "https://www.googleapis.com/drive/v3/drives?pageSize=100",
       &build_drives_row/1}
    ]

    Enum.reduce_while(steps, {:ok, []}, fn {cache_path, url, builder}, {:ok, acc} ->
      case Req.get(url, headers: headers, finch: DmhAi.Finch, receive_timeout: 8_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          schema = builder.(body)
          {:cont, {:ok, acc ++ [%{path: cache_path, schema: schema, expires_at: nil}]}}

        {:ok, %{status: s, body: body}} ->
          {:halt, {:error, {:http, s, body}}}

        {:error, reason} ->
          {:halt, {:error, {:transport, reason}}}
      end
    end)
  end

  # Calendar v3 `calendarList.list` response:
  #   {"items": [%{"id" => "primary" | "<id>@group.calendar.google.com",
  #                "summary" => "<display name>",
  #                "accessRole" => "owner" | "reader" | "writer" | …}, …]}
  # Encode as a single synthetic `calendar_id` property whose options
  # enumerate the user's calendars; the label carries the human name.
  defp build_calendars_row(%{"items" => items}) when is_list(items) do
    options =
      Enum.map(items, fn cal ->
        %{"value" => cal["id"], "label" => cal["summary"]}
      end)

    %{
      "object_type" => "calendars",
      "properties"  => [
        %{"name" => "calendar_id", "type" => "string", "options" => options}
      ]
    }
  end

  defp build_calendars_row(_) do
    %{
      "object_type" => "calendars",
      "properties"  => [%{"name" => "calendar_id", "type" => "string", "options" => []}]
    }
  end

  # Gmail v1 `users.labels.list` response:
  #   {"labels": [%{"id" => "INBOX" | "Label_123",
  #                 "name" => "INBOX" | "Customers/VIP",
  #                 "type" => "system" | "user"}, …]}
  # Encode as a single synthetic `label_id` property whose options
  # enumerate the user's labels; the label carries the display name
  # (system labels are uppercase, user labels keep their nested
  # display path).
  defp build_labels_row(%{"labels" => labels}) when is_list(labels) do
    options =
      Enum.map(labels, fn lbl ->
        %{"value" => lbl["id"], "label" => lbl["name"]}
      end)

    %{
      "object_type" => "gmail.labels",
      "properties"  => [
        %{"name" => "label_id", "type" => "string", "options" => options}
      ]
    }
  end

  defp build_labels_row(_) do
    %{
      "object_type" => "gmail.labels",
      "properties"  => [%{"name" => "label_id", "type" => "string", "options" => []}]
    }
  end

  # Drive v3 `drives.list` response:
  #   {"drives": [%{"id" => "0A…", "name" => "Engineering Shared"}, …]}
  # Encode as a single synthetic `drive_id` property; the label is the
  # shared drive's human name.
  defp build_drives_row(%{"drives" => drives}) when is_list(drives) do
    options =
      Enum.map(drives, fn drv ->
        %{"value" => drv["id"], "label" => drv["name"]}
      end)

    %{
      "object_type" => "drives",
      "properties"  => [
        %{"name" => "drive_id", "type" => "string", "options" => options}
      ]
    }
  end

  defp build_drives_row(_) do
    %{
      "object_type" => "drives",
      "properties"  => [%{"name" => "drive_id", "type" => "string", "options" => []}]
    }
  end
end
