# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.M365.LayerB do
  @moduledoc """
  Layer B for Microsoft 365 — per-user vendor metadata sweep +
  cached-property reader. Lives in its own sub-module because the
  parent `M365` connector is already near the file-size ceiling and
  delegates both callbacks via `defdelegate`.

  Three cache rows go in per user, one per Graph sub-product whose
  identifiers the manifest's args reference directly:

    * `mail.folders` — the user's Outlook mail folders enumerated
      from `GET /me/mailFolders`. Backs `mail.move_to_folder`,
      `mail.read`, `mail.search` whose `folder_id` selects a
      target / scope folder. Well-known folder names (`inbox`,
      `archive`, `sentitems`, …) work too; the cache exposes the
      mailbox-local ids the model can pick from.
    * `calendars` — the user's calendar list from `GET /me/calendars`
      (primary + secondary + shared subscribed). Backs `cal.*`
      functions whose `calendar_id` selects which calendar to read
      or mutate; default is the primary calendar so the cache is
      purely an override surface.
    * `teams.joined` — the Teams the user is a member of, from
      `GET /me/joinedTeams`. Backs `teams.post_channel_message`,
      `teams.list_channels`, `teams.create_meeting` whose `team_id`
      selects a Team scope.

  `inspect_property/3` resolves by exact-name match — `folder_id`
  against the `mail.folders` cache row, `calendar_id` against
  `calendars`, `team_id` against `teams.joined`. The arg names in
  the M365 manifest already match these property names so no
  prefix-stripping is needed.

  The `?$top=100` cap on every endpoint is intentional: SME tenants
  almost never exceed 100 folders / calendars / joined Teams, and a
  single page keeps the sweep simple. OData's `@odata.nextLink`
  pagination walk is deferred until a tenant needs it.
  """

  @behaviour DmhAi.Connectors.Discoverable

  # Map a function bare-name to the cache row whose enum is the source
  # of truth for that function's identifier arg. `inspect_property/3`
  # uses this to route a property lookup at the cached metadata row
  # produced by `discover_metadata/1`.
  @function_to_cache %{
    "mail.move_to_folder"        => "mail.folders",
    "mail.read"                  => "mail.folders",
    "mail.search"                => "mail.folders",
    "cal.create_event"           => "calendars",
    "cal.list_events"            => "calendars",
    "cal.update_event"           => "calendars",
    "cal.find_free_slots"        => "calendars",
    "teams.post_channel_message" => "teams.joined",
    "teams.list_channels"        => "teams.joined",
    "teams.create_meeting"       => "teams.joined"
  }

  # Per-user metadata sweep. Pulls mail folders + calendars + joined
  # Teams in one go using the user's `oauth:m365` credential and
  # returns the three cache rows the `connector_vendor_metadata`
  # table expects. Each step halts the reduce on a non-200 so the
  # runner records the failure against the whole sweep — partial
  # caches are worse than no cache.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "oauth:m365") do
      [%{payload: %{"access_token" => token}} | _] when is_binary(token) ->
        sweep_layer_b(token)

      _ ->
        {:error, :no_m365_credential}
    end
  end

  # Layer B reader. Consult the metadata cache populated by
  # `discover_metadata/1`, locate the matching property by exact
  # name, return its type, label, and vendor's option list as the
  # enum.
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

  # Three-step reduce, one Graph call per sub-product. Microsoft Graph
  # shares a single host (`graph.microsoft.com/v1.0`) so the headers
  # (Bearer auth + JSON accept) are the only repeated piece. The
  # `?$top=100` cap is the vendor's per-request slice; SME tenants
  # almost never exceed 100 folders / calendars / joined Teams. If a
  # deployment ever needs more, walk `@odata.nextLink`.
  defp sweep_layer_b(token) do
    headers = [{"authorization", "Bearer " <> token}, {"accept", "application/json"}]

    steps = [
      {"mail.folders",
       "https://graph.microsoft.com/v1.0/me/mailFolders?$top=100",
       &build_mail_folders_row/1},
      {"calendars",
       "https://graph.microsoft.com/v1.0/me/calendars?$top=100",
       &build_calendars_row/1},
      {"teams.joined",
       "https://graph.microsoft.com/v1.0/me/joinedTeams?$top=100",
       &build_teams_joined_row/1}
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

  # Microsoft Graph's collection envelopes consistently use `value: []`
  # as the list field (OData v4 convention). Extract `[{value, label}]`
  # tuples by reading `id` + the chosen label key (`displayName` for
  # mail folders / Teams, `name` for calendars).
  defp extract_graph_options(%{"value" => items}, label_key) when is_list(items) do
    Enum.map(items, fn item ->
      %{"value" => item["id"], "label" => item[label_key]}
    end)
  end

  defp extract_graph_options(_, _), do: []

  # Graph `/me/mailFolders` response:
  #   {"value": [%{"id" => "AAA...", "displayName" => "Inbox",
  #                "totalItemCount" => 12}, ...]}
  # Encode as a single synthetic `folder_id` property whose options
  # enumerate the user's mail folders; the label carries the
  # displayName (which is what the user sees in Outlook).
  defp build_mail_folders_row(body) do
    %{
      "object_type" => "mail.folders",
      "properties"  => [
        %{"name" => "folder_id", "type" => "string",
          "options" => extract_graph_options(body, "displayName")}
      ]
    }
  end

  # Graph `/me/calendars` response:
  #   {"value": [%{"id" => "BBB...", "name" => "Calendar"}, ...]}
  # Encode as a single synthetic `calendar_id` property whose options
  # enumerate the user's calendars; the label carries the calendar
  # name (Calendars use `name`, not `displayName`).
  defp build_calendars_row(body) do
    %{
      "object_type" => "calendars",
      "properties"  => [
        %{"name" => "calendar_id", "type" => "string",
          "options" => extract_graph_options(body, "name")}
      ]
    }
  end

  # Graph `/me/joinedTeams` response:
  #   {"value": [%{"id" => "CCC...", "displayName" => "Engineering"}, ...]}
  # Encode as a single synthetic `team_id` property; the label is the
  # Team's displayName (AAD group display name).
  defp build_teams_joined_row(body) do
    %{
      "object_type" => "teams.joined",
      "properties"  => [
        %{"name" => "team_id", "type" => "string",
          "options" => extract_graph_options(body, "displayName")}
      ]
    }
  end
end
