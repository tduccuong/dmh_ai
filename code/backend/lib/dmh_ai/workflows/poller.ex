# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Poller do
  @moduledoc """
  Tick-driven dispatcher for armed workflow triggers. Wakes every
  `tick_interval_ms` (default 60_000 = 1 minute), iterates the
  `workflows` table for rows with non-NULL `active_version`, and
  for each armed workflow asks the connector for items NEW since
  the last-stored cursor. Each new item spawns ONE workflow instance
  with the item as the trigger payload.

  Triggers split into two runtime paths:

    * **`poll`** — change-detection. The trigger's
      `connector_function` declares cursor protocol in its manifest
      (`poll_trigger_capable`, `cursor_arg`, `cursor_response_path`,
      `items_path`). On each tick we issue the function with
      `args ++ {cursor_arg: last_cursor}`, walk `items_path` for new
      items, spawn one `Executor.start_run/4` per item, then persist
      the new cursor in `workflow_trigger_state`. **Zero new items
      ⇒ zero instances spawned** — the on-event semantic the spec
      promises.

    * **`schedule`** — cron-style firing. v1: `every_seconds: N`
      cadence (next-fire-time = last_fire + N seconds). Each fire
      spawns ONE instance with a synthetic context payload
      `{fired_at, scheduled_for, owner_user_id}`. Real cron parsing
      lands later.

    * `manual` — never fires from here. Only `invoke_workflow` spawns
      manual instances.

    * `webhook` — never fires from here. Webhook ingress is the
      `/wf/webhook/<wf_id>/<token>` HTTP route; the poller leaves
      webhook-armed workflows alone.

  All cursor + last-fire state is persisted in `workflow_trigger_state`,
  so a node restart doesn't replay or skip ticks. ETS is gone.
  """

  use GenServer
  require Logger

  alias DmhAi.{Workflows, Repo}
  alias DmhAi.Workflows.{Executor, Path}
  alias DmhAi.Tools.Catalog
  alias DmhAi.Connectors.Manifest, as: ConnectorManifest
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_tick_ms 60_000

  # ─── Client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force a tick now (test + manual debugging). Returns the count of
  instances spawned across all armed workflows on this tick.
  """
  def tick_now do
    GenServer.call(__MODULE__, :tick_now, 30_000)
  end

  # ─── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :tick_interval_ms, @default_tick_ms)
    schedule_next(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    n = run_tick()
    {:reply, n, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_tick()
    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  # ─── Tick logic ───────────────────────────────────────────────────────

  defp run_tick do
    now = System.os_time(:millisecond)

    armed_workflows()
    |> Enum.reduce(0, fn wf, spawn_count ->
      case Workflows.get_version(wf.org_id, wf.id, wf.active_version) do
        nil ->
          Logger.warning("[Workflows.Poller] workflow #{wf.org_id}/#{wf.id} active_version=#{wf.active_version} but version row missing; skipping")
          spawn_count

        version ->
          spawned = process_armed(wf, version, now)
          spawn_count + spawned
      end
    end)
  end

  defp armed_workflows do
    %{rows: rows, columns: cols} = query!(Repo, """
    SELECT id, org_id, display_name, created_by, current_version, active_version,
           created_at, updated_at
    FROM workflows WHERE active_version IS NOT NULL
    """, [])

    Enum.map(rows, fn row ->
      Enum.zip(cols, row) |> Map.new() |> atom_keys()
    end)
  end

  defp atom_keys(m) do
    Enum.into(m, %{}, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # ─── Per-workflow trigger dispatch ────────────────────────────────────

  defp process_armed(wf, version, now_ms) do
    trigger = find_trigger_node(version.ir)
    kind    = trigger && Map.get(trigger, "trigger_kind")

    case kind do
      "poll"     -> process_poll(wf, version, trigger, now_ms)
      "schedule" -> process_schedule(wf, version, trigger, now_ms)
      _          -> 0   # manual / webhook / unknown — not the poller's job
    end
  end

  defp find_trigger_node(%{"nodes" => nodes}) when is_list(nodes),
    do: Enum.find(nodes, fn n -> n["kind"] == "trigger" end)

  defp find_trigger_node(_), do: nil

  # ── poll (change detection with cursor) ──────────────────────────────

  defp process_poll(wf, version, trigger, now_ms) do
    every_seconds = Map.get(trigger, "every_seconds")
    state = Workflows.get_trigger_state(wf.org_id, wf.id)

    cond do
      not (is_integer(every_seconds) and every_seconds > 0) ->
        Logger.debug("[Workflows.Poller] #{wf.id}: poll without `every_seconds`; skipping")
        0

      not interval_elapsed?(state, every_seconds, now_ms) ->
        0

      true ->
        fire_poll_cycle(wf, version, trigger, state, now_ms)
    end
  end

  defp interval_elapsed?(nil, _every_seconds, _now_ms), do: true
  defp interval_elapsed?(%{last_fired_at: nil}, _every_seconds, _now_ms), do: true
  defp interval_elapsed?(%{last_fired_at: last}, every_seconds, now_ms),
    do: now_ms - last >= every_seconds * 1000

  # Issue the connector function with the last cursor; extract items
  # from the response per the manifest's `items_path`; spawn one
  # instance per item; persist the new cursor.
  defp fire_poll_cycle(wf, version, trigger, prior_state, now_ms) do
    fn_name = Map.get(trigger, "connector_function")

    case lookup_poll_manifest(fn_name) do
      {:error, reason} ->
        Logger.warning("[Workflows.Poller] #{wf.id}: #{reason}")
        Workflows.upsert_trigger_state(wf.org_id, wf.id, prior_state && prior_state.last_cursor, "error")
        0

      {:ok, manifest} ->
        last_cursor = prior_state && prior_state.last_cursor

        args =
          Map.get(trigger, "connector_args", %{})
          |> maybe_inject_cursor(manifest.cursor_arg, last_cursor)

        ctx = %{
          user_id:        wf.created_by,
          org_id:         wf.org_id,
          task_id:        "poller-#{now_ms}-#{wf.id}",
          step_seq:       Map.get(trigger, "id")
        }

        case Catalog.call(fn_name, args, ctx) do
          {:ok, result} ->
            items      = extract_items(result, manifest.items_path)
            new_cursor = extract_cursor(result, manifest.cursor_response_path) || last_cursor
            status     = if items == [], do: "no_new_items", else: "ok"

            spawned = Enum.reduce(items, 0, fn item, n ->
              spawn_instance_for_item(wf, version, item)
              n + 1
            end)

            Workflows.upsert_trigger_state(wf.org_id, wf.id, new_cursor, status)
            if spawned > 0 do
              Logger.info("[Workflows.Poller] poll #{wf.org_id}/#{wf.id} fn=#{fn_name} new_items=#{spawned}")
            end
            spawned

          {:error, reason} ->
            Logger.error("[Workflows.Poller] poll #{wf.id} fn=#{fn_name} failed: #{inspect(reason, limit: 200)}")
            Workflows.upsert_trigger_state(wf.org_id, wf.id, last_cursor, "error")
            0
        end
    end
  end

  # Look up the poll-trigger manifest from the connector module. Each
  # pollable connector function declares `poll_trigger_capable: true`
  # + the cursor protocol fields. Bare manifest function entries (no
  # poll metadata) refuse — a workflow that wired one as a trigger
  # would have been caught at validate time.
  defp lookup_poll_manifest(nil),
    do: {:error, "poll trigger missing `connector_function`"}

  defp lookup_poll_manifest(fn_name) when is_binary(fn_name) do
    case String.split(fn_name, ".", parts: 2) do
      [slug, bare] ->
        case ConnectorManifest.lookup(slug, bare) do
          nil ->
            {:error, "unknown function `#{fn_name}` in slug `#{slug}`"}

          %{poll_trigger_capable: false} ->
            {:error, "function `#{fn_name}` is not declared poll-trigger-capable"}

          %{} = spec ->
            {:ok, %{
              cursor_arg:           Map.get(spec, :cursor_arg),
              cursor_response_path: Map.get(spec, :cursor_response_path),
              items_path:           Map.get(spec, :items_path)
            }}
        end

      _ ->
        {:error, "function `#{fn_name}` is not namespaced (expected `<slug>.<fn>`)"}
    end
  end

  defp maybe_inject_cursor(args, nil, _cursor), do: args
  defp maybe_inject_cursor(args, _cursor_arg, nil), do: args
  defp maybe_inject_cursor(args, cursor_arg, cursor) when is_binary(cursor_arg),
    do: Map.put(args, cursor_arg, cursor)

  # Parse a path-string + walk the connector's response data.
  defp extract_items(_result, nil), do: []

  defp extract_items(result, path_str) when is_binary(path_str) do
    case parse_jsonpath_like(path_str) do
      {:ok, accessors} ->
        case Path.walk(result, accessors) do
          list when is_list(list) -> list
          _                       -> []
        end

      _ ->
        []
    end
  end

  defp extract_cursor(_result, nil), do: nil

  defp extract_cursor(result, path_str) when is_binary(path_str) do
    case parse_jsonpath_like(path_str) do
      {:ok, accessors} ->
        case Path.walk(result, accessors) do
          :not_found -> nil
          v          -> v
        end

      _ ->
        nil
    end
  end

  # Manifests still use `$.foo.bar[0].baz` JSONPath-ish strings (legacy
  # from the connector spec). Convert to our path tokens by stripping
  # the leading `$.` then parsing the remainder with the workflow Path
  # grammar — same engine, no regex.
  defp parse_jsonpath_like("$" <> rest) do
    rest = String.replace_prefix(rest, ".", "")
    case Path.parse("local." <> rest) do
      {:ok, %{path: [{:key, "local"} | tail]}} -> {:ok, tail}
      {:ok, %{path: tail}}                     -> {:ok, tail}
      err                                       -> err
    end
  end

  defp parse_jsonpath_like(_), do: {:error, "expected JSONPath starting with `$.`"}

  defp spawn_instance_for_item(wf, version, item) do
    owner_id = wf.created_by

    case find_or_pick_session(owner_id) do
      nil ->
        Logger.warning("[Workflows.Poller] no session for owner=#{owner_id}; can't spawn instance for #{wf.id}")

      _sid ->
        task_id = "poller-item-#{System.os_time(:millisecond)}-#{wf.id}"

        exec_ctx = %{org_id: wf.org_id, task_id: task_id}

        Task.start(fn ->
          # The item IS the trigger payload. The trigger node's
          # `extract_emits` projects fields onto node 0's emits per the
          # IR's declared `emits` map; downstream refs (`{{0.field}}` or
          # `{{T.field}}`) walk that.
          case Executor.start_run(wf.id, version.version, normalise_item(item), exec_ctx) do
            {:ok, _run_state} ->
              :ok

            {:error, reason} ->
              Logger.error("[Workflows.Poller] executor failed wf=#{wf.id}: #{inspect(reason)}")
          end
        end)
    end
  end

  # Trigger payloads must be maps so `Executor.start_run/4`'s guard
  # holds. Wrap a non-map item into `{"item" => item}` so the IR can
  # still address it via `{{T.item.<field>}}` when downstream cares.
  defp normalise_item(m) when is_map(m), do: m
  defp normalise_item(other),            do: %{"item" => other}

  # ── schedule (cron-style; v1 uses `every_seconds` cadence) ────────────

  defp process_schedule(wf, version, trigger, now_ms) do
    every_seconds = Map.get(trigger, "every_seconds")
    state         = Workflows.get_trigger_state(wf.org_id, wf.id)

    cond do
      not (is_integer(every_seconds) and every_seconds > 0) ->
        Logger.debug("[Workflows.Poller] #{wf.id}: schedule without `every_seconds`; v1 cron-only unsupported")
        0

      not interval_elapsed?(state, every_seconds, now_ms) ->
        0

      true ->
        owner_id = wf.created_by
        session_id = find_or_pick_session(owner_id)

        case session_id do
          nil ->
            Logger.warning("[Workflows.Poller] no session for owner=#{owner_id}; can't fire schedule #{wf.id}")
            0

          _sid ->
            task_id = "schedule-#{System.os_time(:millisecond)}-#{wf.id}"
            exec_ctx = %{org_id: wf.org_id, task_id: task_id}
            payload  = %{
              "fired_at"        => now_ms,
              "scheduled_for"   => now_ms,
              "owner_user_id"   => owner_id
            }

            Task.start(fn ->
              case Executor.start_run(wf.id, version.version, payload, exec_ctx) do
                {:ok, _} -> :ok
                {:error, reason} ->
                  Logger.error("[Workflows.Poller] schedule fire #{wf.id}: #{inspect(reason)}")
              end
            end)

            Workflows.upsert_trigger_state(wf.org_id, wf.id, nil, "ok")
            1
        end
    end
  end

  # Pick any session belonging to the user — v1 uses the most-recently-
  # active. v2 will create a dedicated "workflow runs" session per user
  # so workflow-fired tasks don't pollute the user's regular chats.
  defp find_or_pick_session(user_id) do
    case query!(Repo, """
    SELECT id FROM sessions WHERE user_id=? ORDER BY updated_at DESC LIMIT 1
    """, [user_id]).rows do
      [[sid]] -> sid
      _       -> nil
    end
  end
end
