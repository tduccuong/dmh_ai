# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AdminPools do
  @moduledoc """
  Admin REST endpoints for the API Pools registry. Renders/edits rows in
  the `pools` table that drive `<pool>::<model>` resolution.

  Routes (admin-only — `user.role == "admin"`):
    GET    /admin/pools           — list rows (api_keys masked)
    POST   /admin/pools           — create
    PUT    /admin/pools/:id       — update
    DELETE /admin/pools/:id       — delete (409 if a model setting still references the pool)
  """

  import Plug.Conn
  alias DmhAi.LLM.{Pools, Probe}
  alias DmhAi.Handlers.Proxy
  require Logger

  # ─── List ────────────────────────────────────────────────────────────────

  def list(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      pools = Pools.list() |> Enum.map(&render(&1, mask: true))
      Proxy.json(conn, 200, %{pools: pools})
    end
  end

  # ─── Create ──────────────────────────────────────────────────────────────

  def create(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      attrs = parse_body(body)

      case Pools.create(attrs) do
        {:ok, pool} ->
          Proxy.json(conn, 201, %{pool: render(pool, mask: false)})

        {:error, :missing_fields} ->
          Proxy.json(conn, 400, %{error: "missing required fields: name, protocol, base_url"})

        {:error, {:invalid_protocol, value}} ->
          Proxy.json(conn, 400, %{
            error: "invalid protocol #{inspect(value)}; must be one of #{inspect(Pools.valid_protocols())}"
          })

        {:error, :name_taken} ->
          Proxy.json(conn, 409, %{error: "pool name already exists"})

        {:error, reason} ->
          Proxy.json(conn, 500, %{error: inspect(reason)})
      end
    end
  end

  @doc """
  Bulk-import pools from a JSON array. Each entry is the same map
  shape `create/2` accepts (name, protocol, base_url, strategy,
  accounts, …). Slug collisions on `name` are skipped (no overwrite).
  Returns a summary
  `%{inserted: N, skipped: M, errors: [{name, error_str}, …]}`.

  This is the FE's "Import" button equivalent — quick-bootstrap
  for fresh installs that don't want to create pools one at a time.
  """
  def import_many(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body || "[]") do
        {:ok, rows} when is_list(rows) ->
          summary = do_import(rows)

          flat_errors =
            Enum.map(summary.errors, fn {name, reason} ->
              %{name: name, error: to_string(reason)}
            end)

          Proxy.json(conn, 200, Map.put(summary, :errors, flat_errors))

        _ ->
          Proxy.json(conn, 400, %{error: "body must be a JSON array of pool entries"})
      end
    end
  end

  defp do_import(rows) do
    init = %{inserted: 0, skipped: 0, errors: []}

    Enum.reduce(rows, init, fn attrs, acc ->
      case Pools.create(attrs) do
        {:ok, _pool}             -> %{acc | inserted: acc.inserted + 1}
        {:error, :name_taken}    -> %{acc | skipped: acc.skipped + 1}
        {:error, reason}         ->
          name = attrs["name"] || attrs[:name] || "(unnamed)"
          %{acc | errors: [{name, reason} | acc.errors]}
      end
    end)
  end

  # ─── Update ──────────────────────────────────────────────────────────────

  def update(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case Integer.parse(id_str) do
        {id, ""} ->
          {:ok, body, conn} = read_body(conn)
          # `accounts` is intentionally stripped — account CRUD goes
          # through the dedicated /accounts endpoints to avoid
          # masked-key replay (the GET response masks keys; PUT-ing
          # them back would clobber real keys with bullets).
          attrs = body |> parse_body() |> Map.drop(["accounts", :accounts])

          case Pools.update(id, attrs) do
            {:ok, pool} -> Proxy.json(conn, 200, %{pool: render(pool, mask: true)})
            {:error, :not_found} -> Proxy.json(conn, 404, %{error: "pool not found"})
            {:error, reason} -> Proxy.json(conn, 500, %{error: inspect(reason)})
          end

        _ ->
          Proxy.json(conn, 400, %{error: "invalid id"})
      end
    end
  end

  def add_account(conn, user, pool_id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case Integer.parse(pool_id_str) do
        {pool_id, ""} ->
          {:ok, body, conn} = read_body(conn)
          attrs = parse_body(body)
          name    = (attrs["name"] || "") |> to_string() |> String.trim()
          api_key = (attrs["api_key"] || attrs["apiKey"] || "") |> to_string() |> String.trim()

          # Probe the new key against the pool's base_url before
          # persisting. Saves the admin from polluting the pool with
          # broken keys.
          with {:ok, pool}     <- Pools.fetch_by_id_safe(pool_id),
               :ok             <- ensure_fields(name, api_key),
               {:ok, _count}   <- Probe.probe(pool.base_url, api_key, pool.protocol) do
            case Pools.add_account(pool_id, name, api_key) do
              {:ok, p}                  -> Proxy.json(conn, 201, %{pool: render(p, mask: true)})
              {:error, :missing_fields} -> Proxy.json(conn, 400, %{error: "name and api_key are required"})
              {:error, :name_taken}     -> Proxy.json(conn, 409, %{error: "account with that name already exists in this pool"})
              {:error, :not_found}      -> Proxy.json(conn, 404, %{error: "pool not found"})
            end
          else
            {:error, :missing_fields} ->
              Proxy.json(conn, 400, %{error: "name and api_key are required"})

            {:error, :pool_not_found} ->
              Proxy.json(conn, 404, %{error: "pool not found"})

            {:error, reason} when is_binary(reason) ->
              Proxy.json(conn, 422, %{error: "probe failed: " <> reason})
          end

        _ ->
          Proxy.json(conn, 400, %{error: "invalid pool id"})
      end
    end
  end

  @doc """
  Fan-out across every pool to discover available models. Used by the
  AI Models settings picker. 5-second cache so debounced FE searches
  don't hammer upstream endpoints. Per-pool failures are surfaced in
  the `errors` array so the FE can decide whether to show diagnostic
  info; the cache only stores SUCCESSFUL pool listings (failing pools
  retry on the next call).
  """
  def list_models(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {models, errors} = fetch_all_models()
      Proxy.json(conn, 200, %{models: models, errors: errors})
    end
  end

  @cache_ttl_ms 5_000

  defp fetch_all_models do
    pools = Pools.list()

    Task.async_stream(pools, &probe_one_pool/1,
      max_concurrency: max(length(pools), 1),
      timeout: 12_000,
      on_timeout: :kill_task)
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, pool_name, names}}, {ok_acc, err_acc} ->
        rows = Enum.map(names, fn n -> %{pool: pool_name, name: n} end)
        {ok_acc ++ rows, err_acc}

      {:ok, {:error, pool_name, reason}}, {ok_acc, err_acc} ->
        {ok_acc, [%{pool: pool_name, error: reason} | err_acc]}

      {:exit, _reason}, {ok_acc, err_acc} ->
        {ok_acc, err_acc}
    end)
  end

  defp probe_one_pool(pool) do
    static = pool.models || []

    cond do
      # Pool ships an explicit static model list — use it verbatim, no
      # HTTP probe. Picker fan-out for endpoints that don't expose
      # /models (e.g. MiniMax's Anthropic-compat host) flows through
      # this branch.
      static != [] ->
        {:ok, pool.name, static}

      true ->
        case cached_models(pool) do
          {:hit, names} ->
            {:ok, pool.name, names}

          :miss ->
            api_key = pool_first_active_key(pool)

            case Probe.list_models(pool.base_url, api_key, pool.protocol) do
              {:ok, names} ->
                cache_put(pool, names)
                {:ok, pool.name, names}

              {:error, reason} ->
                {:error, pool.name, reason}
            end
        end
    end
  end

  defp pool_first_active_key(pool) do
    now = System.os_time(:millisecond)

    pool.accounts
    |> Enum.find(fn acc ->
      tu = acc["throttled_until"]
      is_nil(tu) or tu <= now
    end)
    |> case do
      nil -> ""
      acc -> acc["api_key"] || ""
    end
  end

  # Tiny in-process cache. Key by pool name + base_url so URL edits
  # invalidate. Persistent term avoids ETS setup; per-process is fine
  # because Bandit handlers share VM globals via :persistent_term.
  @cache_term {__MODULE__, :model_cache}

  defp cached_models(pool) do
    cache = :persistent_term.get(@cache_term, %{})
    key = {pool.name, pool.base_url}
    now = System.monotonic_time(:millisecond)

    case Map.get(cache, key) do
      {names, expires_at} when expires_at > now -> {:hit, names}
      _                                          -> :miss
    end
  end

  defp cache_put(pool, names) do
    cache = :persistent_term.get(@cache_term, %{})
    key = {pool.name, pool.base_url}
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :persistent_term.put(@cache_term, Map.put(cache, key, {names, expires_at}))
  end

  def probe(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      attrs = parse_body(body)
      base_url = (attrs["base_url"] || "") |> to_string() |> String.trim()
      api_key  = (attrs["api_key"]  || "") |> to_string() |> String.trim()
      protocol = (attrs["protocol"] || "openai") |> to_string() |> String.trim()

      cond do
        base_url == "" ->
          Proxy.json(conn, 400, %{error: "base_url is required"})

        protocol not in Pools.valid_protocols() ->
          Proxy.json(conn, 400, %{
            error: "invalid protocol #{inspect(protocol)}; must be one of #{inspect(Pools.valid_protocols())}"
          })

        true ->
          case Probe.probe(base_url, api_key, protocol) do
            {:ok, count}      -> Proxy.json(conn, 200, %{ok: true, model_count: count})
            {:error, reason}  -> Proxy.json(conn, 200, %{ok: false, error: reason})
          end
      end
    end
  end

  defp ensure_fields(name, api_key) do
    if name == "" or api_key == "", do: {:error, :missing_fields}, else: :ok
  end

  def remove_account(conn, user, pool_id_str, account_name) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case Integer.parse(pool_id_str) do
        {pool_id, ""} ->
          case Pools.remove_account(pool_id, URI.decode(account_name)) do
            {:ok, pool}          -> Proxy.json(conn, 200, %{pool: render(pool, mask: true)})
            {:error, :not_found} -> Proxy.json(conn, 404, %{error: "pool not found"})
          end

        _ ->
          Proxy.json(conn, 400, %{error: "invalid pool id"})
      end
    end
  end

  # ─── Delete ──────────────────────────────────────────────────────────────

  def delete(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case Integer.parse(id_str) do
        {id, ""} ->
          case Pools.delete(id) do
            :ok                    -> Proxy.json(conn, 200, %{ok: true})
            {:error, :not_found}   -> Proxy.json(conn, 404, %{error: "pool not found"})
            {:error, :referenced}  ->
              Proxy.json(conn, 409, %{error: "pool is referenced by one or more model settings; reassign first"})
          end

        _ ->
          Proxy.json(conn, 400, %{error: "invalid id"})
      end
    end
  end

  # ─── Helpers ─────────────────────────────────────────────────────────────

  defp parse_body(body) do
    case Jason.decode(body || "{}") do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  # `mask: true` masks api_keys for the list view (FE shows `••••••••<last4>`).
  # `mask: false` returns full keys (used by create/update which echo back the
  # row the admin just edited; same admin authority is required to read).
  defp render(pool, opts) do
    masked? = Keyword.get(opts, :mask, true)

    accounts =
      Enum.map(pool.accounts, fn a ->
        full = a["api_key"] || ""
        rendered_key =
          if masked? do
            mask_key(full)
          else
            full
          end

        %{
          name: a["name"] || "",
          api_key: rendered_key,
          throttled_until: a["throttled_until"],
          last_used_ts: a["last_used_ts"]
        }
      end)

    %{
      id: pool.id,
      name: pool.name,
      protocol: pool.protocol,
      base_url: pool.base_url,
      strategy: pool.strategy,
      cooldown_seconds: pool.cooldown_seconds,
      num_ctx: pool.num_ctx,
      accounts: accounts,
      models: pool.models || [],
      created_ts: pool.created_ts,
      updated_ts: pool.updated_ts
    }
  end

  # Fixed-width mask: short keys (≤4 chars) become full bullets; longer
  # keys render as `••••••••<last4>` (8 bullets + last 4 actual chars).
  # Cap is intentional — a literal char-for-char mask of a long token
  # (e.g. a 150-char Anthropic key) blows out the flex layout in
  # System Settings, squeezing the account-name label to zero width.
  @mask_bullets 8

  defp mask_key(""), do: ""
  defp mask_key(key) when is_binary(key) do
    n = String.length(key)
    if n <= 4 do
      String.duplicate("•", n)
    else
      String.duplicate("•", @mask_bullets) <> String.slice(key, n - 4, 4)
    end
  end
end
