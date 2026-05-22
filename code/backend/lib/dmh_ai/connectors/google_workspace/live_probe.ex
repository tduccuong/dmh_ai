# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.LiveProbe do
  @moduledoc """
  Thin wrapper around Google's public **Discovery Document** API. Each
  Google API publishes a machine-readable JSON description at
  `https://www.googleapis.com/discovery/v1/apis/<api>/<version>/rest`
  enumerating every method, its required parameters, accepted OAuth
  scopes, and HTTP shape. No auth required.

  The connector's `discover_functions/0` calls `probe_method/3` to
  fetch the live scope + parameter contract for the underlying Google
  method and overlays it onto the bundled priv-seed row. This lets
  the admin's **Discover Functions** click reveal drift:

    * A Google method whose scope list shrinks (deprecation in
      progress) — our row's `scopes_required` becomes a non-subset.
    * A new required parameter — our row's `args` lacks a key Google
      now demands.

  Net of those, the bundled defaults are still authoritative; the
  live probe's job is *verification*, not replacement.

  HTTP is funnelled through one seam (`http_get/1`) so tests can stub
  it via `Application.put_env(:dmh_ai, :__google_discovery_stub__, fn url -> ... end)`.
  """

  require Logger

  @receive_timeout_ms 5_000

  @doc """
  Fetch one Google API method's live spec. `api_id` is the short name
  (`gmail`, `calendar`, `drive`, ...); `version` is the path segment
  (`v1`, `v3`, ...); `method_id` is the dotted form Google uses in the
  Discovery JSON (`gmail.users.messages.send`).

  Returns:

    * `{:ok, %{scopes: [String.t()], parameters: %{...}, path: String.t(),
              http_method: String.t()}}` — extracted method spec.
    * `{:error, {:method_not_found, method_id}}` — Discovery doc loaded
      but the requested method ID isn't there (typo or method removed).
    * `{:error, {:http, status}}` — non-200 from Google.
    * `{:error, {:transport, reason}}` — network failure / timeout.
    * `{:error, {:decode, reason}}` — body wasn't valid JSON.
  """
  @spec probe_method(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def probe_method(api_id, version, method_id)
      when is_binary(api_id) and is_binary(version) and is_binary(method_id) do
    url = discovery_url(api_id, version)

    with {:ok, body}     <- http_get(url),
         {:ok, json}     <- decode(body),
         {:ok, method}   <- find_method(json, method_id) do
      {:ok, normalise(method)}
    end
  end

  @doc """
  Compose the Discovery Document URL for an `(api_id, version)` pair.
  Exposed for tests + clarity at call sites.
  """
  @spec discovery_url(String.t(), String.t()) :: String.t()
  def discovery_url(api_id, version),
    do: "https://www.googleapis.com/discovery/v1/apis/#{api_id}/#{version}/rest"

  # ─── HTTP seam ──────────────────────────────────────────────────────

  defp http_get(url) do
    case Application.get_env(:dmh_ai, :__google_discovery_stub__) do
      nil ->
        case Req.get(url,
               receive_timeout: @receive_timeout_ms,
               retry: false,
               finch: DmhAi.Finch) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: status}}          -> {:error, {:http, status}}
          {:error, reason}                  -> {:error, {:transport, reason}}
        end

      stub when is_function(stub, 1) ->
        stub.(url)
    end
  end

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json}      -> {:ok, json}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  defp decode(_), do: {:error, {:decode, :unsupported_body_type}}

  # ─── Walk the Discovery JSON tree ──────────────────────────────────
  #
  # Discovery docs nest methods under `resources.<r>.resources.<r>...
  # methods.<m>`. Every method carries its own `id` field (the dotted
  # path) so a recursive walk picking the matching id is simpler than
  # tracking the path through nested resources.

  defp find_method(%{"resources" => _} = json, method_id) do
    case walk_resources(json["resources"], method_id) do
      nil    -> {:error, {:method_not_found, method_id}}
      method -> {:ok, method}
    end
  end

  defp find_method(_, method_id), do: {:error, {:method_not_found, method_id}}

  defp walk_resources(nil, _), do: nil

  defp walk_resources(resources, method_id) when is_map(resources) do
    Enum.find_value(resources, fn {_name, resource} ->
      walk_resource(resource, method_id)
    end)
  end

  defp walk_resource(resource, method_id) when is_map(resource) do
    direct =
      case resource["methods"] do
        nil      -> nil
        methods  -> Enum.find_value(methods, fn {_n, m} ->
                      if m["id"] == method_id, do: m, else: nil
                    end)
      end

    direct || walk_resources(resource["resources"], method_id)
  end

  defp walk_resource(_, _), do: nil

  # ─── Normalise to our shape ────────────────────────────────────────

  defp normalise(method) do
    %{
      scopes:      method["scopes"] || [],
      parameters:  method["parameters"] || %{},
      path:        method["path"],
      http_method: method["httpMethod"]
    }
  end
end
