# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Manifest do
  @moduledoc """
  DB-backed connector function catalog. Source of truth for every
  function's contract — args (with provenance), returns, error
  classes, OAuth scopes. Replaces the code-side `%DmhAi.Tools.Manifest{}`
  literals; vendor changes are absorbed by an admin **Discover
  Functions** click, not a code redeploy.

  Architecture (see `arch_wiki/dmh_ai/sme/layer-W.md` §L1, §Discovery):

      ┌─────────────────────────────────────────────────────────────┐
      │  priv/connectors/<slug>/functions.json   ── seed payload    │
      └─────────────────────────────────────────────────────────────┘
                                  │
                                  │  Seed.load_if_empty/1 at boot,
                                  │  Discovery.run(slug, :functions)
                                  │  on admin click
                                  ▼
      ┌─────────────────────────────────────────────────────────────┐
      │  connector_functions  (DB table)                            │
      │                                                              │
      │  one row per (slug, function_name)                          │
      └─────────────────────────────────────────────────────────────┘
                                  │
                                  │  Manifest.lookup/2
                                  ▼
              `inspect_function` tool, upsert_workflow validator,
              MCPServer.Registry, Dispatcher.

  The connector module's code now carries:
    * `slug/0`, `display_name/0`, `docs_url/0`
    * `discover_functions/1` — fetches vendor spec OR returns
      bundled-priv fallback rows
    * `discover_metadata_sample/2` — per-user vendor metadata probe
    * `discover_docs/0` — KB crawl seed list
    * Runtime caller + shim translators (unchanged)
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @type provenance ::
          %{kind: :from_user,        rationale: String.t() | nil}
          | %{kind: :literal_default, value: term(), rationale: String.t() | nil}
          | %{kind: :lookup,         source: String.t(), result_field: String.t() | nil, rationale: String.t() | nil}
          | %{kind: :built_in,       binding: String.t(), rationale: String.t() | nil}
          | %{kind: :vendor_enum,    enumerate: String.t(), rationale: String.t() | nil}

  @type arg :: %{
          type:        atom() | String.t(),
          required:    boolean(),
          provenance:  provenance() | nil,
          format:      atom() | String.t() | nil,
          enum:        [String.t()] | nil,
          description: String.t() | nil
        }

  @type function_spec :: %{
          connector_slug:        String.t(),
          function_name:         String.t(),
          permission:            atom(),
          args:                  %{String.t() => arg()},
          returns:               %{atom() => atom()},
          error_classes:         [atom()],
          scopes_required:       [String.t()],
          idempotency_key:       atom(),
          callable_from:         [atom()],
          poll_trigger_capable:  boolean(),
          cursor_arg:            String.t() | nil,
          cursor_response_path:  String.t() | nil,
          items_path:            String.t() | nil,
          min_poll_seconds:      integer() | nil,
          default_poll_seconds:  integer() | nil,
          discovered_at:         integer(),
          discovered_by:         String.t()
        }

  @doc """
  Look up one function's contract. Returns `nil` when the function
  hasn't been discovered for this connector yet (the admin needs to
  click **Discover Functions**).
  """
  @spec lookup(String.t(), String.t()) :: function_spec() | nil
  def lookup(slug, function_name)
      when is_binary(slug) and is_binary(function_name) do
    case query!(Repo, """
    SELECT connector_slug, function_name, permission, args_json, returns_json,
           error_classes_json, scopes_required_json, idempotency_key,
           callable_from_json, poll_trigger_capable, cursor_arg,
           cursor_response_path, items_path, min_poll_seconds,
           default_poll_seconds, discovered_at, discovered_by
    FROM connector_functions
    WHERE connector_slug = ? AND function_name = ?
    """, [slug, function_name]).rows do
      [row] -> row_to_spec(row)
      _     -> nil
    end
  end

  def lookup(_, _), do: nil

  @doc """
  Look up by fully-qualified name `"<slug>.<function>"`. Convenience
  wrapper around `lookup/2` for call sites that handle FQNs (workflow
  IR, system prompts, `inspect_function` tool input).
  """
  @spec lookup_fqn(String.t()) :: function_spec() | nil
  def lookup_fqn(fqn) when is_binary(fqn) do
    case String.split(fqn, ".", parts: 2) do
      [slug, bare] -> lookup(slug, bare)
      _            -> nil
    end
  end

  def lookup_fqn(_), do: nil

  @doc """
  List every function discovered for a slug. Order: by function_name.
  """
  @spec list_for_slug(String.t()) :: [function_spec()]
  def list_for_slug(slug) when is_binary(slug) do
    %{rows: rows} = query!(Repo, """
    SELECT connector_slug, function_name, permission, args_json, returns_json,
           error_classes_json, scopes_required_json, idempotency_key,
           callable_from_json, poll_trigger_capable, cursor_arg,
           cursor_response_path, items_path, min_poll_seconds,
           default_poll_seconds, discovered_at, discovered_by
    FROM connector_functions
    WHERE connector_slug = ?
    ORDER BY function_name
    """, [slug])

    Enum.map(rows, &row_to_spec/1)
  end

  @doc """
  Replace all function rows for a connector. Atomic: either the new
  set wins entirely or nothing changes. Called by `Discovery.run/2`
  after a successful Discover.
  """
  @spec replace_all(String.t(), [map()], String.t()) :: {:ok, non_neg_integer()}
  def replace_all(slug, function_rows, discovered_by)
      when is_binary(slug) and is_list(function_rows) and is_binary(discovered_by) do
    now = System.os_time(:millisecond)

    Repo.transaction(fn ->
      query!(Repo, "DELETE FROM connector_functions WHERE connector_slug=?", [slug])

      Enum.each(function_rows, fn row ->
        insert_row(slug, row, now, discovered_by)
      end)
    end)

    {:ok, length(function_rows)}
  end

  @doc """
  Count rows for a slug. `0` means "this slug has never been
  discovered" — the boot-time seed loader uses this to decide
  whether to load `priv/connectors/<slug>/functions.json`.
  """
  @spec count_for_slug(String.t()) :: non_neg_integer()
  def count_for_slug(slug) when is_binary(slug) do
    %{rows: [[n]]} =
      query!(Repo, "SELECT COUNT(*) FROM connector_functions WHERE connector_slug=?", [slug])

    n
  end

  # ─── row encode / decode ─────────────────────────────────────────────

  defp insert_row(slug, row, now, discovered_by) do
    query!(Repo, """
    INSERT INTO connector_functions
      (connector_slug, function_name, permission, args_json, returns_json,
       error_classes_json, scopes_required_json, idempotency_key,
       callable_from_json, poll_trigger_capable, cursor_arg,
       cursor_response_path, items_path, min_poll_seconds,
       default_poll_seconds, discovered_at, discovered_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      slug,
      Map.fetch!(row, :function_name),
      to_string(Map.get(row, :permission, :read)),
      Jason.encode!(Map.get(row, :args, %{})),
      Jason.encode!(Map.get(row, :returns, %{})),
      Jason.encode!(Map.get(row, :error_classes, [])),
      Jason.encode!(Map.get(row, :scopes_required, [])),
      to_string(Map.get(row, :idempotency_key, :none)),
      Jason.encode!(Map.get(row, :callable_from, [:chat, :task])),
      bool_int(Map.get(row, :poll_trigger_capable, false)),
      Map.get(row, :cursor_arg),
      Map.get(row, :cursor_response_path),
      Map.get(row, :items_path),
      Map.get(row, :min_poll_seconds),
      Map.get(row, :default_poll_seconds),
      now,
      discovered_by
    ])
  end

  defp row_to_spec([slug, fn_name, perm, args_json, returns_json,
                    err_json, scopes_json, idem, callable_json, poll_cap,
                    cursor_arg, cursor_resp_path, items_path, min_poll,
                    default_poll, discovered_at, discovered_by]) do
    %{
      connector_slug:        slug,
      function_name:         fn_name,
      permission:            String.to_atom(perm),
      args:                  decode_args(args_json),
      returns:               Jason.decode!(returns_json) |> stringify_keys(),
      error_classes:         Jason.decode!(err_json || "[]") |> Enum.map(&safe_atom/1),
      scopes_required:       Jason.decode!(scopes_json || "[]"),
      idempotency_key:       String.to_atom(idem),
      callable_from:         Jason.decode!(callable_json || "[]") |> Enum.map(&safe_atom/1),
      poll_trigger_capable:  poll_cap == 1,
      cursor_arg:            cursor_arg,
      cursor_response_path:  cursor_resp_path,
      items_path:            items_path,
      min_poll_seconds:      min_poll,
      default_poll_seconds:  default_poll,
      discovered_at:         discovered_at,
      discovered_by:         discovered_by
    }
  end

  defp decode_args(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), decode_arg(v)} end)
  end

  defp decode_arg(%{} = m) do
    %{
      type:        m["type"]        |> safe_atom_or_string(),
      required:    m["required"]    || false,
      provenance:  decode_provenance(m["provenance"]),
      format:      m["format"]      |> safe_atom_or_string_or_nil(),
      enum:        m["enum"],
      description: m["description"]
    }
    |> compact()
  end

  defp decode_provenance(nil), do: nil
  defp decode_provenance(%{"kind" => kind} = p) do
    p
    |> Enum.into(%{}, fn
      {"kind", k}    -> {:kind, safe_atom(k)}
      {"value", v}   -> {:value, v}
      {"source", s}  -> {:source, s}
      {"binding", b} -> {:binding, b}
      {"enumerate", f} -> {:enumerate, f}
      {"result_field", f} -> {:result_field, f}
      {"rationale", r} -> {:rationale, r}
      {k, v}         -> {String.to_atom(k), v}
    end)
    |> Map.put(:kind, safe_atom(kind))
  end

  defp decode_provenance(_), do: nil

  defp stringify_keys(m) when is_map(m),
    do: Enum.into(m, %{}, fn {k, v} -> {to_string(k), v} end)

  defp safe_atom(nil),                       do: nil
  defp safe_atom(s) when is_atom(s),         do: s
  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> String.to_atom(s)
  end

  defp safe_atom_or_string(nil),                       do: nil
  defp safe_atom_or_string(s) when is_atom(s),         do: s
  defp safe_atom_or_string(s) when is_binary(s) do
    case s do
      "string" -> :string
      "number" -> :number
      "integer"-> :integer
      "boolean"-> :boolean
      "map"    -> :map
      "list"   -> :list
      _        -> s
    end
  end

  defp safe_atom_or_string_or_nil(nil), do: nil
  defp safe_atom_or_string_or_nil(s),   do: safe_atom_or_string(s)

  defp compact(m), do: Enum.reject(m, fn {_k, v} -> is_nil(v) end) |> Enum.into(%{})

  defp bool_int(true),  do: 1
  defp bool_int(false), do: 0
  defp bool_int(_),      do: 0
end
