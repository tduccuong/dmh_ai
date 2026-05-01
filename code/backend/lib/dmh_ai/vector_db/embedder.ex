# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Embedder do
  @moduledoc """
  HTTP client for the embedding endpoint resolved via
  `DmhAi.LLM.Pools` from `AgentSettings.kb_embedding_model()` (default
  `miner::qwen3-embedding:0.6b`). Speaks the OpenAI-compatible
  `POST /embeddings` shape that Ollama exposes.

  Test hook: `Application.put_env(:dmh_ai, :__embedder_stub__, fn texts -> {:ok, [vec, ...]} end)`.
  When set, the stub bypasses the HTTP path entirely. Stubs are
  responsible for returning vectors of the correct dimension.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.LLM.{Pools, AccountRotation}
  require Logger

  @doc "Embed a single text. Convenience over `embed_batch/1`."
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [vec]} -> {:ok, vec}
      {:ok, _}     -> {:error, :unexpected_count}
      err          -> err
    end
  end

  @doc """
  Embed a list of texts. Splits into batches of `kb_embedding_batch_size`
  and concatenates the result. Stops at first error.
  """
  @spec embed_batch([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(texts) when is_list(texts) do
    case Application.get_env(:dmh_ai, :__embedder_stub__) do
      stub when is_function(stub, 1) ->
        stub.(texts)

      _ ->
        batch_size = AgentSettings.kb_embedding_batch_size()

        texts
        |> Enum.chunk_every(batch_size)
        |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
          case do_request(batch) do
            {:ok, vecs} -> {:cont, {:ok, acc ++ vecs}}
            {:error, _} = err -> {:halt, err}
          end
        end)
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp do_request(batch) do
    model_str = AgentSettings.kb_embedding_model()
    expected_dim = AgentSettings.kb_embedding_dim()

    case Pools.resolve(model_str) do
      {:ok, resolved} ->
        url = embeddings_url(resolved)
        headers = build_headers(resolved)
        body = %{model: resolved.model, input: batch}

        case Req.post(url,
               json: body,
               headers: headers,
               receive_timeout: 60_000,
               retry: false,
               finch: DmhAi.Finch
             ) do
          {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
            vecs = data |> Enum.sort_by(&(&1["index"] || 0)) |> Enum.map(&(&1["embedding"] || []))
            assert_dim(vecs, expected_dim)

          {:ok, %{status: 200, body: body}} ->
            {:error, "unexpected response shape: #{inspect(body, limit: 200)}"}

          {:ok, %{status: 429} = resp} ->
            mark_throttled(resolved, resp)
            {:error, :rate_limited}

          {:ok, %{status: status, body: body}} ->
            Logger.error("[Embedder] HTTP #{status}: #{inspect(body, limit: 200)}")
            {:error, "embeddings endpoint returned HTTP #{status}"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :all_throttled, retry_ms} ->
        {:error, {:all_throttled, retry_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assert_dim(vecs, expected) do
    bad =
      Enum.find_index(vecs, fn v ->
        not is_list(v) or length(v) != expected
      end)

    if is_nil(bad) do
      {:ok, vecs}
    else
      got = if is_list(Enum.at(vecs, bad)), do: length(Enum.at(vecs, bad)), else: :not_a_list
      {:error, "embedding dim mismatch at index #{bad}: got #{inspect(got)}, expected #{expected}"}
    end
  end

  defp embeddings_url(%{base_url: base}) do
    base = String.trim_trailing(base, "/")
    base <> "/embeddings"
  end

  defp build_headers(%{api_key: ""}), do: [{"content-type", "application/json"}]
  defp build_headers(%{api_key: key}),
    do: [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}]

  defp mark_throttled(resolved, resp) do
    secs = AgentSettings.rate_limit_throttle_secs()
    until = System.os_time(:millisecond) + parse_retry_after_ms(resp.headers, secs * 1000)
    AccountRotation.mark_throttled(resolved.pool_name, resolved.account_name, until)
  end

  defp parse_retry_after_ms(headers, default_ms) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      [v | _] when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {secs, ""} when secs > 0 -> secs * 1000
          _ -> default_ms
        end

      _ -> default_ms
    end
  end
  defp parse_retry_after_ms(_, default_ms), do: default_ms
end
