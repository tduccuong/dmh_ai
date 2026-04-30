# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Handlers.AdminSeeds do
  @moduledoc """
  Admin REST endpoints for Wiki Seeds — pre-loaded URLs that can
  be batch-`/wiki`ed into the global `:knowledge` scope. See
  specs/vector_kb.md.

  Routes (admin-only, gated below):
    GET    /admin/wiki-seeds          — list rows; lazily merges priv/kb_seeds/preloaded.json on first call
    POST   /admin/wiki-seeds          — add a custom URL
    DELETE /admin/wiki-seeds/:id      — remove
    POST   /admin/wiki-seeds/:id/run  — kick off /wiki for a single seed (background)
    POST   /admin/wiki-seeds/run-all  — kick off /wiki for every seed (background)

  Run dispatch is currently a stub — it stamps `last_status='queued'`
  and logs a message. The actual URL-crawl pipeline lives in #162;
  this handler is the BE plumbing the FE wires into.
  """

  import Plug.Conn
  alias Dmhai.Handlers.Proxy
  alias Dmhai.VectorDB.Seeds
  require Logger

  def list(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      :ok = Seeds.ensure_preloaded()
      Proxy.json(conn, 200, %{seeds: Seeds.list()})
    end
  end

  def create(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      attrs = parse_body(body)

      case Seeds.create(attrs) do
        {:ok, seed} -> Proxy.json(conn, 201, %{seed: seed})
        {:error, :missing_url} -> Proxy.json(conn, 400, %{error: "missing required field: url"})
        {:error, :url_taken}   -> Proxy.json(conn, 409, %{error: "url already exists"})
      end
    end
  end

  def delete(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case Integer.parse(id_str) do
        {id, ""} ->
          case Seeds.delete(id) do
            :ok -> Proxy.json(conn, 200, %{ok: true})
            {:error, :not_found} -> Proxy.json(conn, 404, %{error: "seed not found"})
          end

        _ ->
          Proxy.json(conn, 400, %{error: "invalid id"})
      end
    end
  end

  def run_one(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case Integer.parse(id_str) do
        {id, ""} ->
          spawn(fn -> dispatch_run(id) end)
          Proxy.json(conn, 202, %{ok: true, queued: id})

        _ ->
          Proxy.json(conn, 400, %{error: "invalid id"})
      end
    end
  end

  def run_all(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      ids = Seeds.list() |> Enum.map(& &1.id)
      Enum.each(ids, fn id -> spawn(fn -> dispatch_run(id) end) end)
      Proxy.json(conn, 202, %{ok: true, queued: length(ids)})
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp parse_body(body) do
    case Jason.decode(body || "{}") do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  # Run a single seed — fetch + index via the same Web.Fetcher +
  # VectorDB.ingest pipeline that `/wiki <url>` uses. Synchronous
  # within this Task; the calling spawn returns immediately so the
  # admin's HTTP request resolves with 202 Accepted.
  defp dispatch_run(id) do
    Seeds.mark_run(id, "queued", nil)

    case Enum.find(Seeds.list(), &(&1.id == id)) do
      nil ->
        Logger.warning("[Seeds] run requested for missing seed id=#{id}")
        :ok

      seed ->
        case Dmhai.Web.Fetcher.fetch(seed.url, extractor: :kb, max_chars: 200_000) do
          {:ok, %{title: title, content: text}} when is_binary(text) and text != "" ->
            attrs = %{
              scope:       :knowledge,
              user_id:     nil,
              source_kind: "url",
              source_ref:  seed.url,
              title:       seed.label || title || seed.url
            }

            case Dmhai.VectorDB.ingest(attrs, text) do
              {:ok, %{indexed: n}} ->
                Seeds.mark_run(id, "ok", "Indexed #{n} chunks")
                Logger.info("[Seeds] id=#{id} url=#{seed.url} indexed=#{n}")

              {:error, reason} ->
                Seeds.mark_run(id, "error", "Ingest failed: #{inspect(reason, limit: 80)}")
            end

          {:ok, _} ->
            Seeds.mark_run(id, "error", "No readable content extracted")

          {:error, reason} ->
            Seeds.mark_run(id, "error", "Fetch failed: #{inspect(reason, limit: 100)}")
        end
    end
  rescue
    e ->
      Seeds.mark_run(id, "error", "Crash: #{Exception.message(e)}")
  end
end
