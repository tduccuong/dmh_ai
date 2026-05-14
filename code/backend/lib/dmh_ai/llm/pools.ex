# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.Pools do
  @moduledoc """
  Pool registry — owns reads/writes to the `pools` table and the
  `<pool>::<model>` resolution path used by `DmhAi.Agent.LLM`.

  See `arch_wiki/dmh_ai/integrations.md` §API Pools for the conceptual
  model. A *pool* bundles the endpoint config (base_url, protocol,
  account list, rotation strategy); a *model* string is opaque and
  passed through to the upstream service. The wire protocol is
  declared by `protocol` (one of `"openai"`, `"ollama"`, `"anthropic"`)
  — see `DmhAi.LLM.Adapter` and `DmhAi.Agent.LLM.adapter_for/1`.

  Resolution shape:

      Pools.resolve("miner::qwen3-embedding:0.6b")
      → {:ok, %{
           pool_name:    "miner",
           model:        "qwen3-embedding:0.6b",
           base_url:     "http://192.168.178.49:11434/v1",
           protocol:     "ollama",
           num_ctx:      16384,           # nil when not set
           account_name: "local",
           api_key:      "sk-local"
         }}

  Returns `{:error, :unknown_pool}` for unrecognised pool names and
  `{:error, :all_throttled, retry_after_ms}` when every account in the
  pool is throttled (caller surfaces honestly to the user — no silent
  failover to a different pool).
  """

  alias DmhAi.Repo
  alias DmhAi.LLM.AccountRotation
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @valid_protocols ~w(openai ollama anthropic)

  @type pool :: %{
          id: integer(),
          name: String.t(),
          protocol: String.t(),
          base_url: String.t(),
          strategy: String.t(),
          cooldown_seconds: non_neg_integer(),
          num_ctx: pos_integer() | nil,
          accounts: [map()],
          models: [String.t()],
          rr_cursor: non_neg_integer()
        }

  @type resolved :: %{
          pool_name: String.t(),
          model: String.t(),
          base_url: String.t(),
          protocol: String.t(),
          num_ctx: pos_integer() | nil,
          account_name: String.t(),
          api_key: String.t()
        }

  @doc "The complete set of accepted protocol values."
  @spec valid_protocols() :: [String.t()]
  def valid_protocols, do: @valid_protocols

  # ─── Public API ────────────────────────────────────────────────────────────

  @doc """
  Parse and resolve a `<pool>::<model>` string. The pool is looked up;
  account rotation picks one account; the resolved struct is returned
  ready for the LLM client + adapter dispatch to use.
  """
  @spec resolve(String.t()) ::
          {:ok, resolved()}
          | {:error, :invalid_format | :unknown_pool}
          | {:error, :all_throttled, non_neg_integer()}
  def resolve(model_str) when is_binary(model_str) do
    with {:ok, pool_name, model} <- parse(model_str),
         {:ok, pool}              <- fetch(pool_name),
         {:ok, account}           <- AccountRotation.pick(pool) do
      {:ok,
       %{
         pool_name:    pool.name,
         model:        model,
         base_url:     pool.base_url,
         protocol:     pool.protocol,
         num_ctx:      pool.num_ctx,
         account_name: account["name"] || "",
         api_key:      account["api_key"] || ""
       }}
    end
  end

  @doc """
  Split a canonical model string into `{:ok, pool_name, model}` or
  `{:error, :invalid_format}`. Pool name is always the part before the
  first `::`; everything after is opaque model text (may contain `:` or `/`).
  """
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_format}
  def parse(model_str) when is_binary(model_str) do
    case String.split(model_str, "::", parts: 2) do
      [pool, model] when pool != "" and model != "" -> {:ok, pool, model}
      _                                               -> {:error, :invalid_format}
    end
  end

  @doc "List all pools. Used by /admin/pools and the System Settings UI."
  @spec list() :: [pool()]
  def list do
    r = query!(Repo, """
    SELECT id, name, protocol, base_url, strategy, cooldown_seconds,
           num_ctx, accounts, models, rr_cursor, created_ts, updated_ts
    FROM pools
    ORDER BY id ASC
    """, [])

    Enum.map(r.rows, &row_to_map/1)
  end

  @doc "Fetch a pool by id."
  @spec fetch_by_id_safe(integer()) :: {:ok, pool()} | {:error, :pool_not_found}
  def fetch_by_id_safe(id) when is_integer(id) do
    case fetch_by_id(id) do
      {:ok, _} = ok -> ok
      _             -> {:error, :pool_not_found}
    end
  end

  @doc "Fetch a pool by name."
  @spec fetch(String.t()) :: {:ok, pool()} | {:error, :unknown_pool}
  def fetch(name) when is_binary(name) do
    r = query!(Repo, """
    SELECT id, name, protocol, base_url, strategy, cooldown_seconds,
           num_ctx, accounts, models, rr_cursor, created_ts, updated_ts
    FROM pools WHERE name=?
    """, [name])

    case r.rows do
      [row] -> {:ok, row_to_map(row)}
      _     -> {:error, :unknown_pool}
    end
  end

  @doc """
  Create a new pool. `attrs` keys: name, protocol, base_url, strategy,
  cooldown_seconds, accounts. Returns `{:ok, pool}`,
  `{:error, :missing_fields}`, `{:error, {:invalid_protocol, value}}`,
  or `{:error, :name_taken}`.
  """
  @spec create(map()) :: {:ok, pool()} | {:error, atom() | {atom(), term()}}
  def create(attrs) do
    with {:ok, normalised} <- validate(attrs),
         :ok               <- check_name_free(normalised["name"]) do
      now = System.os_time(:millisecond)
      org_id = Map.get(attrs, "org_id") || Map.get(attrs, :org_id) || DmhAi.Orgs.default_id()

      query!(Repo, """
      INSERT INTO pools (org_id, name, protocol, base_url, strategy,
                         cooldown_seconds, num_ctx, accounts, models,
                         rr_cursor, created_ts, updated_ts)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
      """, [
        org_id,
        normalised["name"],
        normalised["protocol"],
        normalised["base_url"],
        normalised["strategy"],
        normalised["cooldown_seconds"],
        normalised["num_ctx"],
        Jason.encode!(normalised["accounts"]),
        Jason.encode!(normalised["models"]),
        now, now
      ])

      fetch(normalised["name"])
    end
  end

  @doc "Update an existing pool by id. `attrs` may carry any subset of fields."
  @spec update(integer(), map()) :: {:ok, pool()} | {:error, atom()}
  def update(id, attrs) when is_integer(id) do
    case fetch_by_id(id) do
      {:ok, existing} ->
        merged = Map.merge(existing_to_attrs(existing), normalise_partial(attrs))
        do_update(id, merged)
        fetch(merged["name"])

      err -> err
    end
  end

  @doc """
  Add an account to a pool. Returns `{:ok, pool}` on success,
  `{:error, :name_taken}` if the pool already has an account by that
  name, `{:error, :missing_fields}` for blank inputs.
  """
  @spec add_account(integer(), String.t(), String.t()) :: {:ok, pool()} | {:error, atom()}
  def add_account(pool_id, name, api_key) when is_integer(pool_id) do
    name    = String.trim(name || "")
    api_key = String.trim(api_key || "")

    cond do
      name == "" or api_key == "" ->
        {:error, :missing_fields}

      true ->
        with {:ok, pool} <- fetch_by_id(pool_id) do
          if Enum.any?(pool.accounts, &(&1["name"] == name)) do
            {:error, :name_taken}
          else
            new_accounts = pool.accounts ++ [%{"name" => name, "api_key" => api_key}]
            do_update(pool_id, Map.put(existing_to_attrs(pool), "accounts", new_accounts))
            fetch(pool.name)
          end
        end
    end
  end

  @doc "Remove an account from a pool by name."
  @spec remove_account(integer(), String.t()) :: {:ok, pool()} | {:error, atom()}
  def remove_account(pool_id, account_name) when is_integer(pool_id) do
    with {:ok, pool} <- fetch_by_id(pool_id) do
      kept = Enum.reject(pool.accounts, &(&1["name"] == account_name))
      do_update(pool_id, Map.put(existing_to_attrs(pool), "accounts", kept))
      fetch(pool.name)
    end
  end

  @doc "Delete a pool by id. Returns `{:error, :referenced}` if any model setting points at this pool."
  @spec delete(integer()) :: :ok | {:error, atom()}
  def delete(id) when is_integer(id) do
    case fetch_by_id(id) do
      {:ok, pool} ->
        if referenced?(pool.name) do
          {:error, :referenced}
        else
          query!(Repo, "DELETE FROM pools WHERE id=?", [id])
          :ok
        end

      err -> err
    end
  end

  @doc """
  Persist rotation state on the named pool: refresh `last_used_ts` for
  the picked account, optionally stamp `throttled_until`, optionally
  bump the round-robin cursor. Atomic via SQLite UPDATE on the row.

  Called by `AccountRotation` after a pick (mark_used) and by the LLM
  client on rate-limit (mark_throttled).
  """
  @spec update_account(String.t(), String.t(), keyword()) :: :ok
  def update_account(pool_name, account_name, opts \\ []) do
    now           = System.os_time(:millisecond)
    mark_used     = Keyword.get(opts, :mark_used, false)
    throttled_ms  = Keyword.get(opts, :throttled_until)
    rr_cursor     = Keyword.get(opts, :rr_cursor)

    with {:ok, pool} <- fetch(pool_name) do
      updated_accounts =
        Enum.map(pool.accounts, fn acc ->
          if (acc["name"] || acc["api_key"]) == account_name do
            acc
            |> maybe_put("last_used_ts", if(mark_used, do: now, else: acc["last_used_ts"]))
            |> maybe_put("throttled_until", throttled_ms)
          else
            acc
          end
        end)

      sql =
        if rr_cursor != nil do
          "UPDATE pools SET accounts=?, rr_cursor=?, updated_ts=? WHERE name=?"
        else
          "UPDATE pools SET accounts=?, updated_ts=? WHERE name=?"
        end

      args =
        if rr_cursor != nil,
          do: [Jason.encode!(updated_accounts), rr_cursor, now, pool_name],
          else: [Jason.encode!(updated_accounts), now, pool_name]

      query!(Repo, sql, args)
      :ok
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp fetch_by_id(id) do
    r = query!(Repo, """
    SELECT id, name, protocol, base_url, strategy, cooldown_seconds,
           num_ctx, accounts, models, rr_cursor, created_ts, updated_ts
    FROM pools WHERE id=?
    """, [id])

    case r.rows do
      [row] -> {:ok, row_to_map(row)}
      _     -> {:error, :not_found}
    end
  end

  defp validate(attrs) do
    name = trim_str(attrs["name"] || attrs[:name])
    protocol = trim_str(attrs["protocol"] || attrs[:protocol])
    base_url = trim_str(attrs["base_url"] || attrs[:base_url])

    cond do
      name == "" or protocol == "" or base_url == "" ->
        {:error, :missing_fields}

      protocol not in @valid_protocols ->
        {:error, {:invalid_protocol, protocol}}

      true ->
        {:ok,
         %{
           "name" => name,
           "protocol" => protocol,
           "base_url" => base_url,
           "strategy" => trim_str(attrs["strategy"] || attrs[:strategy] || "least_used"),
           "cooldown_seconds" => attrs["cooldown_seconds"] || attrs[:cooldown_seconds] || 300,
           "num_ctx" => normalise_num_ctx(attrs["num_ctx"] || attrs[:num_ctx]),
           "accounts" => normalise_accounts(attrs["accounts"] || attrs[:accounts] || []),
           "models" => normalise_models(attrs["models"] || attrs[:models] || [])
         }}
    end
  end

  defp normalise_partial(attrs) do
    keys = ~w(name protocol base_url strategy cooldown_seconds num_ctx accounts models)

    Enum.reduce(keys, %{}, fn k, acc ->
      v = Map.get(attrs, k) || Map.get(attrs, String.to_atom(k))

      cond do
        is_nil(v) -> acc
        k == "accounts" -> Map.put(acc, k, normalise_accounts(v))
        k == "models" -> Map.put(acc, k, normalise_models(v))
        k == "num_ctx" -> Map.put(acc, k, normalise_num_ctx(v))
        is_binary(v) -> Map.put(acc, k, String.trim(v))
        true -> Map.put(acc, k, v)
      end
    end)
  end

  # Normalise the static-models field. Accepts a list of strings, a
  # newline/comma-separated string, or nil. Trims, drops blanks, dedups.
  defp normalise_models(nil), do: []

  defp normalise_models(list) when is_list(list) do
    list
    |> Enum.map(fn v -> v |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalise_models(s) when is_binary(s) do
    s
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalise_models(_), do: []

  # `num_ctx` accepts integers, integer-looking strings, or anything
  # else (which we treat as "blank → NULL"). Empty strings, "null",
  # zero, and negatives all become nil — only a positive integer
  # gets through to the column.
  defp normalise_num_ctx(nil), do: nil
  defp normalise_num_ctx(n) when is_integer(n) and n > 0, do: n
  defp normalise_num_ctx(n) when is_integer(n), do: nil
  defp normalise_num_ctx(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _                  -> nil
    end
  end
  defp normalise_num_ctx(_), do: nil

  defp normalise_accounts(list) when is_list(list) do
    Enum.map(list, fn a ->
      a = if is_struct(a), do: Map.from_struct(a), else: a
      %{
        "name"    => to_string(a["name"]    || a[:name]    || ""),
        "api_key" => to_string(a["api_key"] || a[:api_key] || a["apiKey"] || a[:apiKey] || "")
      }
      |> maybe_put("throttled_until", a["throttled_until"] || a[:throttled_until])
      |> maybe_put("last_used_ts",    a["last_used_ts"]    || a[:last_used_ts])
    end)
  end

  defp normalise_accounts(_), do: []

  defp existing_to_attrs(pool) do
    %{
      "name" => pool.name,
      "protocol" => pool.protocol,
      "base_url" => pool.base_url,
      "strategy" => pool.strategy,
      "cooldown_seconds" => pool.cooldown_seconds,
      "num_ctx" => pool.num_ctx,
      "accounts" => pool.accounts,
      "models" => pool.models
    }
  end

  defp do_update(id, attrs) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE pools SET name=?, protocol=?, base_url=?,
                     strategy=?, cooldown_seconds=?, num_ctx=?,
                     accounts=?, models=?, updated_ts=?
    WHERE id=?
    """, [
      attrs["name"], attrs["protocol"], attrs["base_url"],
      attrs["strategy"], attrs["cooldown_seconds"], attrs["num_ctx"],
      Jason.encode!(attrs["accounts"]),
      Jason.encode!(attrs["models"] || []),
      now, id
    ])
  end

  defp check_name_free(name) do
    case fetch(name) do
      {:ok, _}              -> {:error, :name_taken}
      {:error, :unknown_pool} -> :ok
    end
  end

  # A pool is "referenced" if any model-role setting in admin_cloud_settings
  # uses it as the prefix of a `<pool>::<model>` string. Defensive — settings
  # may carry pool prefixes our own `@defaults` don't, e.g. operator-customised
  # roles.
  defp referenced?(pool_name) do
    r = query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

    case r.rows do
      [[v] | _] when is_binary(v) ->
        decoded = Jason.decode!(v || "{}")
        Enum.any?(decoded, fn {_k, val} ->
          is_binary(val) and String.starts_with?(val, pool_name <> "::")
        end)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp trim_str(nil), do: ""
  defp trim_str(s) when is_binary(s), do: String.trim(s)
  defp trim_str(other), do: to_string(other)

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v),    do: Map.put(map, k, v)

  defp row_to_map([id, name, protocol, base_url, strategy, cooldown_seconds,
                   num_ctx, accounts_json, models_json, rr_cursor,
                   created_ts, updated_ts]) do
    %{
      id: id,
      name: name,
      protocol: protocol,
      base_url: base_url,
      strategy: strategy,
      cooldown_seconds: cooldown_seconds,
      num_ctx: num_ctx,
      accounts: decode_json_list(accounts_json),
      models: decode_models(models_json),
      rr_cursor: rr_cursor,
      created_ts: created_ts,
      updated_ts: updated_ts
    }
  end

  defp decode_json_list(nil), do: []
  defp decode_json_list(""),  do: []
  defp decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _                              -> []
    end
  end

  # `models` is a list of strings; defensively skip non-string entries.
  defp decode_models(json) do
    json
    |> decode_json_list()
    |> Enum.filter(&is_binary/1)
  end
end
