# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.OAuth.Userinfo do
  @moduledoc """
  Fetches the account identifier from a provider's userinfo endpoint
  using a freshly-issued access token. Output goes into
  `user_credentials.account` so multi-account support can fan out
  per-account requests in the tool layer.

  Inputs come from the catalog row (`userinfo_endpoint`,
  `userinfo_field_path`) and the live token. The field path is dotted
  JSON traversal — `"email"`, `"data.username"`, `"user.encodedId"`.
  Array indices are not supported here; if a provider returns the
  account in an array (Twitch's `data[0].login`) the catalog row
  leaves both fields NULL and the callback handler falls back to
  `account = ""` (the unlabelled default).

  Network errors, HTTP errors, missing fields, malformed JSON — all
  resolve to `{:error, reason}`. Callers log and proceed with
  `account = ""`; failing the OAuth callback because we couldn't
  identify the account is worse UX than storing the credential as a
  default-account row.
  """

  require Logger

  @receive_timeout_ms 10_000

  @doc """
  Returns `{:ok, account_string}` on success or `{:error, reason}` on
  any failure (catalog row has no userinfo configured, network blew
  up, field absent in response, etc.). The returned string is
  trimmed; if it would be empty after trim, we treat it as a miss.
  """
  @spec fetch(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(catalog_row, access_token) when is_map(catalog_row) and is_binary(access_token) do
    endpoint = Map.get(catalog_row, :userinfo_endpoint)
    path     = Map.get(catalog_row, :userinfo_field_path)

    cond do
      not is_binary(endpoint) or endpoint == "" ->
        {:error, :no_userinfo_endpoint}

      not is_binary(path) or path == "" ->
        {:error, :no_userinfo_field_path}

      true ->
        do_fetch(endpoint, path, access_token)
    end
  end

  def fetch(_, _), do: {:error, :bad_input}

  # ── private ──────────────────────────────────────────────────────────────

  defp do_fetch(endpoint, path, access_token) do
    headers = [
      {"authorization", "Bearer " <> access_token},
      {"accept", "application/json"}
    ]

    case Req.get(endpoint,
           headers: headers,
           receive_timeout: @receive_timeout_ms,
           retry: false,
           finch: DmhAi.Finch) do
      {:ok, %{status: 200, body: body}} ->
        case decode_body(body) do
          {:ok, json} ->
            case extract_field(json, path) do
              v when is_binary(v) and v != "" -> {:ok, String.trim(v)}
              v when is_integer(v) -> {:ok, Integer.to_string(v)}
              _ -> {:error, {:field_missing, path}}
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
      Logger.warning("[OAuth.Userinfo] fetch raised: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # `Req` returns the body already-decoded when content-type is
  # application/json. Some providers send text/plain for OAuth-style
  # endpoints; fall back to manual decode in that case.
  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body) when is_list(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, e} -> {:error, e}
    end
  end

  defp decode_body(other), do: {:error, {:unexpected_body, inspect(other)}}

  # Dotted-path JSON extraction. Walks an arbitrarily nested
  # %{"a" => %{"b" => "c"}} via `"a.b"`. Returns nil for any missing
  # segment. Atom-keyed maps would be unusual at this hop (Req gives
  # string keys for decoded JSON) but we tolerate them defensively.
  defp extract_field(json, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(json, fn
      _seg, nil -> nil
      seg, m when is_map(m) -> Map.get(m, seg) || Map.get(m, String.to_existing_atom(seg))
      _seg, _other -> nil
    end)
  rescue
    ArgumentError -> nil
  end
end
