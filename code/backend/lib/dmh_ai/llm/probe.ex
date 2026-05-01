# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.Probe do
  @moduledoc """
  Connectivity probe for an OpenAI-compatible endpoint. Used by the
  System Settings → API Pools UI to verify URL + key combinations
  before persisting a save.

  GETs `<base_url>/models` (the standard OpenAI listing endpoint).
  Returns `{:ok, model_count}` on HTTP 200, `{:error, reason_string}`
  on anything else.
  """

  require Logger

  @timeout_ms 8_000

  @spec probe(String.t(), String.t() | nil) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def probe(base_url, api_key) when is_binary(base_url) do
    url = String.trim_trailing(base_url, "/") <> "/models"

    headers =
      case api_key do
        k when is_binary(k) and k != "" -> [{"authorization", "Bearer " <> k}]
        _                               -> []
      end

    case Req.get(url, headers: headers, receive_timeout: @timeout_ms, retry: false, finch: DmhAi.Finch) do
      {:ok, %{status: 200, body: body}} ->
        count = body_model_count(body)
        {:ok, count}

      {:ok, %{status: 401}} ->
        {:error, "401 Unauthorized — API key rejected by upstream"}

      {:ok, %{status: 403}} ->
        {:error, "403 Forbidden — API key not authorised for this endpoint"}

      {:ok, %{status: 404}} ->
        {:error, "404 Not Found — endpoint doesn't expose /models (wrong base URL?)"}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} from #{url}"}

      {:error, %{reason: reason}} when is_atom(reason) ->
        {:error, "Connection failed: #{reason}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason, limit: 80)}"}
    end
  end

  defp body_model_count(%{"data" => list}) when is_list(list), do: length(list)
  defp body_model_count(%{"models" => list}) when is_list(list), do: length(list)
  defp body_model_count(_), do: 0

  @doc """
  List models from `<base_url>/models`. Returns `{:ok, [name, ...]}`
  on 200, `{:error, reason}` otherwise. Used by the pool-aware model
  picker — see `DmhAi.Handlers.AdminPools.list_models/2`.
  """
  @spec list_models(String.t(), String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_models(base_url, api_key) when is_binary(base_url) do
    url = String.trim_trailing(base_url, "/") <> "/models"

    headers =
      case api_key do
        k when is_binary(k) and k != "" -> [{"authorization", "Bearer " <> k}]
        _                               -> []
      end

    case Req.get(url, headers: headers, receive_timeout: @timeout_ms, retry: false, finch: DmhAi.Finch) do
      {:ok, %{status: 200, body: body}} -> {:ok, body_model_names(body)}
      {:ok, %{status: status}}          -> {:error, "HTTP #{status}"}
      {:error, %{reason: reason}}       -> {:error, "Connection failed: #{reason}"}
      {:error, reason}                  -> {:error, "Connection failed: #{inspect(reason, limit: 80)}"}
    end
  end

  defp body_model_names(%{"data" => list}) when is_list(list) do
    Enum.flat_map(list, fn
      %{"id" => id} when is_binary(id) -> [id]
      _                                 -> []
    end)
  end

  defp body_model_names(%{"models" => list}) when is_list(list) do
    # Ollama-native shape: [{"name": "qwen3:8b", ...}, ...]
    Enum.flat_map(list, fn
      %{"name" => n} when is_binary(n) -> [n]
      _                                 -> []
    end)
  end

  defp body_model_names(_), do: []
end
