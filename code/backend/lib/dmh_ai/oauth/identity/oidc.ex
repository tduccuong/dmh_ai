# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.OAuth.Identity.OIDC do
  @moduledoc """
  Shared identity-fetcher for OAuth providers that follow the OIDC
  userinfo pattern: `GET <endpoint>` with `Authorization: Bearer <token>`,
  body is JSON, the email lives at a known field path.

  Connector modules that fit this pattern implement
  `OAuthIdentity.fetch_userinfo/1` as a one-liner delegating here:

      def fetch_userinfo(token),
        do: OAuth.Identity.OIDC.fetch(token,
              "https://openidconnect.googleapis.com/v1/userinfo", "email")

  Connectors that don't (e.g. HubSpot's token-in-path introspect
  endpoint, or providers needing multi-step calls) implement the
  callback directly without going through this helper.
  """

  require Logger

  @receive_timeout_ms 5_000

  @doc """
  Fetch identity via the OIDC userinfo pattern.

  * `access_token` — the OAuth access token, sent as Bearer auth.
  * `endpoint` — the userinfo URL (e.g. `https://.../userinfo`).
  * `field_path` — dotted JSONPath of the email field
    (`"email"` for OIDC standard, `"resource.email"` for Calendly,
    `"user"` for HubSpot's token-introspect — but HubSpot uses the
    path-token endpoint so it doesn't go through here).

  Returns `{:ok, %{email: ...}}` on success or `{:error, reason}`.
  The shape matches `OAuthIdentity.identity()` so the finalize path
  can use the result uniformly.
  """
  @spec fetch(String.t(), String.t(), String.t()) ::
          {:ok, %{email: String.t()}} | {:error, term()}
  def fetch(access_token, endpoint, field_path)
      when is_binary(access_token) and is_binary(endpoint) and is_binary(field_path) do
    case http_get(endpoint, [
           {"authorization", "Bearer " <> access_token},
           {"accept", "application/json"}
         ]) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, json} ->
            case extract(json, field_path) do
              v when is_binary(v) and v != "" -> {:ok, %{email: String.trim(v)}}
              v when is_integer(v)             -> {:ok, %{email: Integer.to_string(v)}}
              _ -> {:error, {:field_missing, field_path}}
            end

          {:error, reason} ->
            {:error, {:decode, reason}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  rescue
    e ->
      Logger.warning("[OAuth.Identity.OIDC] fetch raised: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # HTTP seam — stubbable via Application env for tests (mirrors the
  # `__oauth2_http_stub__` / `__google_discovery_stub__` patterns).
  defp http_get(url, headers) do
    case Application.get_env(:dmh_ai, :__oidc_userinfo_stub__) do
      nil ->
        Req.get(url,
          headers: headers,
          receive_timeout: @receive_timeout_ms,
          retry: false,
          finch: DmhAi.Finch)

      stub when is_function(stub, 2) ->
        stub.(url, headers)
    end
  end

  defp decode(body) when is_map(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: {:error, :unsupported_body_type}

  # Dotted-path field extraction. `"resource.email"` walks
  # `json["resource"]["email"]`. Atom-keyed fallback covers Elixir
  # structs that some upstream code already decodes; the OAuth path
  # always sees JSON-decoded maps with string keys so the atom branch
  # is defensive.
  defp extract(json, field_path) do
    field_path
    |> String.split(".")
    |> Enum.reduce(json, fn _seg, :error -> :error
                            seg, acc when is_map(acc) ->
                              case Map.fetch(acc, seg) do
                                {:ok, v} -> v
                                :error ->
                                  case Map.fetch(acc, String.to_atom(seg)) do
                                    {:ok, v} -> v
                                    :error -> :error
                                  end
                              end
                            _seg, _ -> :error
                         end)
  end
end
