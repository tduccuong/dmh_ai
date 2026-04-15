# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.DomainBlocker do
  use GenServer
  require Logger
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  @table :blocked_domains
  @threshold 3

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns true if the URL's root domain is blocked."
  def blocked?(url) do
    try do
      rd = root_domain_from_url(url)
      if rd == "" do
        false
      else
        :ets.member(@table, rd)
      end
    rescue
      _ -> false
    end
  end

  @doc "Record a fetch timeout for this URL; auto-block if threshold reached."
  def record_timeout(url) do
    GenServer.cast(__MODULE__, {:record_timeout, url})
  end

  @doc "Reload blocked domains from DB."
  def load_from_db do
    GenServer.call(__MODULE__, :load_from_db)
  end

  # Server callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{timeout_counts: %{}}}
  end

  @impl true
  def handle_call(:load_from_db, _from, state) do
    domains = load_domains_from_db()
    :ets.delete_all_objects(@table)

    Enum.each(domains, fn domain ->
      :ets.insert(@table, {domain, true})
    end)

    Logger.info("[BLOCKED] loaded #{length(domains)} domains")
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record_timeout, url}, state) do
    rd = root_domain_from_url(url)

    if rd == "" or :ets.member(@table, rd) do
      {:noreply, state}
    else
      counts = state.timeout_counts
      new_count = Map.get(counts, rd, 0) + 1
      new_counts = Map.put(counts, rd, new_count)

      new_state =
        if new_count >= @threshold do
          :ets.insert(@table, {rd, true})
          persist_blocked_domain(rd, new_count)
          Logger.info("[BLOCKED] auto-blocked #{rd} after #{new_count} timeouts")
          %{state | timeout_counts: new_counts}
        else
          %{state | timeout_counts: new_counts}
        end

      {:noreply, new_state}
    end
  end

  # Helpers

  defp load_domains_from_db do
    try do
      result = query!(Repo, "SELECT domain FROM blocked_domains")
      Enum.map(result.rows, fn [d] -> d end)
    rescue
      e ->
        Logger.error("[BLOCKED] failed to load from DB: #{inspect(e)}")
        []
    end
  end

  defp persist_blocked_domain(domain, count) do
    now = :os.system_time(:second)

    try do
      query!(Repo, """
      INSERT OR REPLACE INTO blocked_domains (domain, reason, timeout_count, added_at)
      VALUES (?, ?, ?, ?)
      """, [domain, "auto:timeout", count, now])
    rescue
      e -> Logger.error("[BLOCKED] failed to persist #{domain}: #{inspect(e)}")
    end
  end

  @doc "Extract the registrable domain (last two labels) from a URL."
  def root_domain_from_url(url) do
    try do
      uri = URI.parse(url)
      hostname = uri.host || ""
      root_domain(hostname)
    rescue
      _ -> ""
    end
  end

  def root_domain(hostname) do
    parts = hostname |> String.downcase() |> String.split(".")

    if length(parts) >= 2 do
      parts |> Enum.take(-2) |> Enum.join(".")
    else
      String.downcase(hostname)
    end
  end
end
