# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.Probe do
  @moduledoc """
  Connectivity probe for a pool endpoint. Used by the System Settings →
  API Pools UI to verify URL + key combinations and to populate the
  per-pool model picker.

  GETs `<base_url>/models` and parses the response per protocol:

    * `openai` / `ollama` — Bearer auth, OpenAI-shape `{"data": [...]}` or
      Ollama-native `{"models": [...]}` body
    * `anthropic` — `x-api-key` + `anthropic-version` headers,
      `{"data": [{"id": "..."}]}` body

  Not every Anthropic-shaped endpoint exposes a listing route (some
  third-party Anthropic-compat hosts don't); the picker tolerates
  empty / failed responses by surfacing the pool in the per-pool error
  list and letting the operator type the model id manually.
  """

  require Logger

  @timeout_ms 8_000

  @spec probe(String.t(), String.t() | nil, String.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def probe(base_url, api_key, protocol) when is_binary(base_url) and is_binary(protocol) do
    url = String.trim_trailing(base_url, "/") <> "/models"
    headers = auth_headers(protocol, api_key)

    case Req.get(url, headers: headers, receive_timeout: @timeout_ms, retry: false, finch: DmhAi.Finch) do
      {:ok, %{status: 200, body: body}} ->
        count = body_model_count(body)
        {:ok, count}

      {:ok, %{status: 401}} ->
        {:error, "401 Unauthorized — API key rejected by upstream"}

      {:ok, %{status: 403}} ->
        {:error, "403 Forbidden — API key not authorised for this endpoint"}

      # Anthropic-compat hosts (MiniMax, OpenRouter's anthropic shim,
      # etc.) often only implement /v1/messages — no /models listing
      # route. A 404 here is expected and shouldn't block pool create;
      # operator supplies model IDs manually via the static list.
      {:ok, %{status: 404}} when protocol == "anthropic" ->
        {:ok, 0}

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
  @spec list_models(String.t(), String.t() | nil, String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def list_models(base_url, api_key, protocol)
      when is_binary(base_url) and is_binary(protocol) do
    url = String.trim_trailing(base_url, "/") <> "/models"
    headers = auth_headers(protocol, api_key)

    case Req.get(url, headers: headers, receive_timeout: @timeout_ms, retry: false, finch: DmhAi.Finch) do
      {:ok, %{status: 200, body: body}}              -> {:ok, body_model_names(body)}
      # Same anthropic-compat caveat as `probe/3` — a 404 here means
      # "this endpoint doesn't list models", not an error. Picker
      # fan-out shows an empty list for such pools, which the static
      # models column then fills in.
      {:ok, %{status: 404}} when protocol == "anthropic" -> {:ok, []}
      {:ok, %{status: status}}                       -> {:error, "HTTP #{status}"}
      {:error, %{reason: reason}}                    -> {:error, "Connection failed: #{reason}"}
      {:error, reason}                               -> {:error, "Connection failed: #{inspect(reason, limit: 80)}"}
    end
  end

  # Per-protocol auth headers. OpenAI/Ollama take Bearer; Anthropic
  # rejects Bearer and requires `x-api-key` + `anthropic-version`.
  defp auth_headers("anthropic", api_key),
    do: DmhAi.LLM.Adapters.Anthropic.auth_headers(api_key || "")

  defp auth_headers(_protocol, api_key) when is_binary(api_key) and api_key != "",
    do: [{"authorization", "Bearer " <> api_key}]

  defp auth_headers(_protocol, _),
    do: []

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
