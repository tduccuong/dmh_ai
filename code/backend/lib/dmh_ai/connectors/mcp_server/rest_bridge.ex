# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer.RestBridge do
  @moduledoc """
  Single HTTP entry point for the MCPServer pipeline. Every
  outbound HTTP call made by a connector — whether driven by a
  `VerbSpec` or by a custom handler function — passes through
  this module. Tests intercept by setting
  `:__rest_bridge_http_stub__` in application env to a 2-arity
  function `(method, req_opts) -> {:ok, status, body} | {:error,
  reason}`.

  Public surface:

    * `invoke/3` — execute a `VerbSpec` (default path for verbs
      that are 1:1 REST mappings).
    * `simple_get/3`, `simple_post/3` — utilities for custom
      handlers that need multiple HTTP calls but use standard
      JSON / query-string shapes (e.g. Gmail's search +
      per-message metadata fan-out).
    * `raw_request/2` — escape hatch for handlers that need full
      Req option control (multipart, custom headers).

  All three honor the stub so a single per-test stub can intercept
  every outbound call from a handler.
  """

  alias DmhAi.Connectors.MCPServer.{ErrorMap, VerbSpec}
  require Logger

  # ─── Public: VerbSpec invocation ────────────────────────────────────────

  @doc """
  Execute a `VerbSpec` against the vendor API. See module doc
  for the stub-test convention.
  """
  @spec invoke(VerbSpec.t(), map(), map()) ::
          {:ok, term()} | {:error, atom()}
  def invoke(%VerbSpec{handler: fun}, args, ctx)
      when is_function(fun, 2) and is_map(args) and is_map(ctx) do
    # Escape hatch — verb owns its own orchestration. Bridge
    # doesn't touch :method / :url / :request / :response here.
    fun.(args, ctx)
  end

  def invoke(%VerbSpec{} = spec, args, ctx) when is_map(args) and is_map(ctx) do
    url = resolve_url(spec.url, args)
    req_opts = build_req_opts(spec, args, ctx)

    case do_request(spec.method, [{:url, url} | req_opts]) do
      {:ok, status, body} when status in 200..299 ->
        apply_response(spec, status, body)

      {:ok, status, body} ->
        case apply_response(spec, status, body) do
          {:error, _} = err -> err
          _ ->
            classified = ErrorMap.classify(status, body)
            Logger.debug(
              "[RestBridge] non-2xx status=#{status} → #{classified} url=#{url}"
            )
            {:error, classified}
        end

      {:error, reason} ->
        Logger.warning("[RestBridge] transport error url=#{url} reason=#{inspect(reason)}")
        {:error, :transport_error}
    end
  end

  # ─── Public: handler utility helpers ────────────────────────────────────

  @doc """
  GET with optional query params. Returns `{:ok, body}` on 2xx,
  `{:error, atom}` otherwise. Used by custom handlers for vendor
  sub-calls.
  """
  @spec simple_get(String.t(), keyword() | list({String.t(), term()}), map()) ::
          {:ok, term()} | {:error, atom()}
  def simple_get(url, query, ctx) when is_binary(url) and is_map(ctx) do
    opts =
      [url: url, query: query]
      |> add_bearer_to_opts(ctx)

    case do_request(:get, opts) do
      {:ok, status, body} when status in 200..299 -> {:ok, body}
      {:ok, status, body} -> {:error, ErrorMap.classify(status, body)}
      {:error, _}         -> {:error, :transport_error}
    end
  end

  @doc """
  POST JSON. Returns `{:ok, body}` on 2xx, `{:error, atom}`
  otherwise.
  """
  @spec simple_post(String.t(), map(), map()) ::
          {:ok, term()} | {:error, atom()}
  def simple_post(url, json_body, ctx) when is_binary(url) and is_map(ctx) do
    opts =
      [url: url, json: json_body]
      |> add_bearer_to_opts(ctx)

    case do_request(:post, opts) do
      {:ok, status, body} when status in 200..299 -> {:ok, body}
      {:ok, status, body} -> {:error, ErrorMap.classify(status, body)}
      {:error, _}         -> {:error, :transport_error}
    end
  end

  @doc """
  Full Req option control. Caller supplies the entire option list
  (including :url, :method, :headers, :body, :multipart, etc.).
  Used by handlers that need multipart uploads or other shapes
  not expressible as plain JSON.
  """
  @spec raw_request(atom(), keyword()) :: {:ok, integer(), term()} | {:error, term()}
  def raw_request(method, opts) when is_atom(method) and is_list(opts) do
    do_request(method, opts)
  end

  # ─── Internal helpers ──────────────────────────────────────────────────

  defp resolve_url(url, _args) when is_binary(url), do: url
  defp resolve_url(fun, args) when is_function(fun, 1), do: fun.(args)

  defp build_req_opts(%VerbSpec{} = spec, args, ctx) do
    raw =
      case spec.request do
        nil  -> default_request(spec.method, args)
        fun when is_function(fun, 2) -> fun.(args, ctx)
        fun when is_function(fun, 1) -> fun.(args)
      end

    raw
    |> normalize_opts()
    |> add_bearer_to_opts(ctx)
  end

  defp default_request(method, args) when method in [:get, :delete],
    do: [query: stringify_keys(args)]

  defp default_request(_method, args), do: [json: args]

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  defp add_bearer_to_opts(opts, %{bearer_token: token}) when is_binary(token) and token != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"authorization", "Bearer " <> token} | headers])
  end

  defp add_bearer_to_opts(opts, _), do: opts

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      kv -> kv
    end)
  end

  # Response handling for VerbSpec invocations (not utility helpers).

  defp apply_response(%VerbSpec{response: nil}, status, body) when status in 200..299 do
    case body do
      m when is_map(m) -> {:ok, m}
      other            -> {:ok, %{"text" => to_string_safe(other)}}
    end
  end

  defp apply_response(%VerbSpec{response: nil}, _status, _body), do: :passthrough

  defp apply_response(%VerbSpec{response: fun}, status, body) when is_function(fun, 2) do
    try do
      case fun.(status, body) do
        {:ok, _}    = ok  -> ok
        {:error, _} = err -> err
        other -> {:error, {:bad_response_transform, other}}
      end
    rescue
      # Verb's response function didn't pattern-match this status —
      # fall through to default classification (the bridge will then
      # apply `ErrorMap.classify/2` for non-2xx). Lets per-verb
      # response functions stay focused on success-shape mapping
      # without enumerating every HTTP error code.
      FunctionClauseError -> :passthrough
    end
  end

  defp to_string_safe(b) when is_binary(b), do: b
  defp to_string_safe(b), do: inspect(b)

  # ─── Transport (stubbed in tests) ──────────────────────────────────────

  defp do_request(method, opts) do
    case Application.get_env(:dmh_ai, :__rest_bridge_http_stub__) do
      stub when is_function(stub, 2) ->
        stub.(method, opts)

      _ ->
        opts = Keyword.put(opts, :method, method)

        case Req.request(opts) do
          {:ok, %Req.Response{status: status, body: body}} ->
            {:ok, status, body}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
