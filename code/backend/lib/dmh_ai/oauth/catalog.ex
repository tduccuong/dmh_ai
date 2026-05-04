# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.OAuth.Catalog do
  @moduledoc """
  Read-side accessor for the operator-curated `oauth_catalog` table.

  The catalog holds one row per OAuth-protected REST service the
  operator has registered an OAuth app with (Google Cloud Console,
  Slack app config, etc.). Each row carries the
  authorization/token endpoints, default scopes, and the
  client_id/client_secret produced by that registration.

  The catalog is the source of truth for *which services the model
  may attempt to authorize on the user's behalf*. Hosts that are
  not in the catalog return `nil` from `get_by_host/1` and the
  `authorize_service` tool returns a clean `{:error, ...}` to the
  model.

  Per-user OAuth tokens land in `user_credentials` at
  `target = "oauth:<host_match>"`. The catalog itself never holds
  user tokens — only the operator-side OAuth-app credentials.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @type entry :: %{
          id:                     pos_integer(),
          slug:                   String.t(),
          display_name:           String.t(),
          host_match:             String.t(),
          authorization_endpoint: String.t(),
          token_endpoint:         String.t(),
          scopes_default:         [String.t()],
          client_id:              String.t(),
          client_secret:          String.t() | nil,
          extra_auth_params:      map(),
          extra_token_params:     map(),
          enabled:                boolean()
        }

  @doc """
  Look up a catalog entry by exact slug. Returns `nil` for unknown
  slugs OR for disabled rows — disabled entries are invisible to
  callers, same as in the MCP catalog.
  """
  @spec get_by_slug(String.t()) :: entry() | nil
  def get_by_slug(slug) when is_binary(slug) and slug != "" do
    query_one("WHERE slug = ? AND enabled = 1", [slug])
  end

  def get_by_slug(_), do: nil

  @doc """
  Look up a catalog entry by host or URL. The match is
  longest-host-prefix: an entry with `host_match = "googleapis.com"`
  matches any URL whose host ends in that suffix
  (`www.googleapis.com`, `calendar.googleapis.com`, etc.).

  When the input is a full URL we extract the host portion before
  matching. Callers may pass either form.

  Returns `nil` when no enabled entry covers the host.
  """
  @spec get_by_host(String.t()) :: entry() | nil
  def get_by_host(input) when is_binary(input) and input != "" do
    host = extract_host(input)

    if host == "" do
      nil
    else
      enabled_entries()
      |> Enum.filter(fn e -> host == e.host_match or String.ends_with?(host, "." <> e.host_match) end)
      # Longest match wins — `googleapis.com` over `com` for
      # `calendar.googleapis.com`.
      |> Enum.sort_by(fn e -> -byte_size(e.host_match) end)
      |> List.first()
    end
  end

  def get_by_host(_), do: nil

  @doc "All enabled entries — used by chat-time host matching."
  @spec all_enabled() :: [entry()]
  def all_enabled, do: enabled_entries()

  @doc "Every row, enabled OR disabled — used by the admin UI."
  @spec list_all() :: [entry()]
  def list_all do
    %{rows: rows} =
      query!(Repo,
        """
        SELECT id, slug, display_name, host_match,
               authorization_endpoint, token_endpoint,
               scopes_default, client_id, client_secret,
               extra_auth_params, extra_token_params, enabled
        FROM oauth_catalog
        ORDER BY display_name
        """,
        [])

    Enum.map(rows, &row_to_entry/1)
  end

  @doc """
  Create a new catalog entry. Required keys (string or atom): slug,
  display_name, host_match, authorization_endpoint, token_endpoint.
  Returns `{:ok, entry}` or `{:error, reason}`.
  """
  @spec create(map()) :: {:ok, entry()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    with {:ok, normalised} <- normalise(attrs),
         :ok               <- validate_required(normalised) do
      now = System.os_time(:millisecond)

      try do
        query!(Repo,
          """
          INSERT INTO oauth_catalog
            (slug, display_name, host_match,
             authorization_endpoint, token_endpoint,
             scopes_default, client_id, client_secret,
             extra_auth_params, extra_token_params,
             enabled, created_ts, updated_ts)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            normalised.slug,
            normalised.display_name,
            normalised.host_match,
            normalised.authorization_endpoint,
            normalised.token_endpoint,
            Jason.encode!(normalised.scopes_default),
            normalised.client_id || "",
            normalised.client_secret,
            Jason.encode!(normalised.extra_auth_params),
            Jason.encode!(normalised.extra_token_params),
            if(normalised.enabled, do: 1, else: 0),
            now,
            now
          ])

        # New rows default to enabled=0 so get_by_slug/1 (which
        # filters on enabled=1) won't find them. Use the unfiltered
        # lookup for the write-side return.
        {:ok, query_one("WHERE slug = ?", [normalised.slug])}
      rescue
        e -> {:error, Exception.message(e)}
      end
    end
  end

  @doc """
  Update an existing entry by id. `attrs` is partial — only present
  keys are written. Empty-string `client_secret` means *don't change*
  (so the FE can submit the form without re-typing the secret each
  edit). Pass `client_secret: nil` to clear it.
  """
  @spec update(pos_integer(), map()) :: {:ok, entry()} | {:error, term()}
  def update(id, attrs) when is_integer(id) and is_map(attrs) do
    with {:ok, normalised} <- normalise(attrs, partial: true) do
      case query_one("WHERE id = ?", [id]) do
        nil ->
          {:error, :not_found}

        %{} = current ->
          merged   = Map.merge(current, normalised)
          secret   = resolve_secret(attrs, current.client_secret)
          now      = System.os_time(:millisecond)

          try do
            query!(Repo,
              """
              UPDATE oauth_catalog
              SET slug = ?, display_name = ?, host_match = ?,
                  authorization_endpoint = ?, token_endpoint = ?,
                  scopes_default = ?, client_id = ?, client_secret = ?,
                  extra_auth_params = ?, extra_token_params = ?,
                  enabled = ?, updated_ts = ?
              WHERE id = ?
              """,
              [
                merged.slug,
                merged.display_name,
                merged.host_match,
                merged.authorization_endpoint,
                merged.token_endpoint,
                Jason.encode!(merged.scopes_default),
                merged.client_id || "",
                secret,
                Jason.encode!(merged.extra_auth_params),
                Jason.encode!(merged.extra_token_params),
                if(merged.enabled, do: 1, else: 0),
                now,
                id
              ])

            {:ok, query_one("WHERE id = ?", [id])}
          rescue
            e -> {:error, Exception.message(e)}
          end
      end
    end
  end

  @doc "Delete an entry by id. No-op when the row doesn't exist."
  @spec delete(pos_integer()) :: :ok
  def delete(id) when is_integer(id) do
    query!(Repo, "DELETE FROM oauth_catalog WHERE id = ?", [id])
    :ok
  end

  # ── normalisation ────────────────────────────────────────────────────────

  defp normalise(attrs, opts \\ []) do
    partial = Keyword.get(opts, :partial, false)

    out =
      attrs
      |> stringify_keys()
      |> Map.take(~w(slug display_name host_match authorization_endpoint
                      token_endpoint scopes_default client_id client_secret
                      extra_auth_params extra_token_params enabled))
      |> Enum.into(%{}, fn
        {"scopes_default",    v} -> {:scopes_default,     normalise_scopes(v)}
        {"extra_auth_params", v} -> {:extra_auth_params,  normalise_map(v)}
        {"extra_token_params", v} -> {:extra_token_params, normalise_map(v)}
        {"enabled",           v} -> {:enabled, !!v}
        {k, v} -> {String.to_atom(k), v}
      end)

    out =
      if partial do
        out
      else
        out
        |> Map.put_new(:scopes_default,     [])
        |> Map.put_new(:extra_auth_params,  %{})
        |> Map.put_new(:extra_token_params, %{})
        |> Map.put_new(:enabled,            false)
      end

    {:ok, out}
  end

  defp validate_required(attrs) do
    required = [:slug, :display_name, :host_match, :authorization_endpoint, :token_endpoint]

    case Enum.find(required, fn k -> blank?(Map.get(attrs, k)) end) do
      nil -> :ok
      key -> {:error, "field `#{key}` is required"}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""),  do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp normalise_scopes(v) when is_list(v) do
    v |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp normalise_scopes(v) when is_binary(v) do
    v
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalise_scopes(_), do: []

  defp normalise_map(v) when is_map(v), do: v
  defp normalise_map(_), do: %{}

  defp stringify_keys(m) when is_map(m) do
    Enum.into(m, %{}, fn
      {k, v} when is_atom(k)   -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
      pair                      -> pair
    end)
  end

  # On update, an empty-string client_secret means "don't change the
  # stored value" — standard secret-handling pattern. nil means
  # "clear the value". Anything else replaces it.
  defp resolve_secret(attrs, current_secret) do
    case Map.get(attrs, "client_secret", Map.get(attrs, :client_secret, :unset)) do
      :unset -> current_secret
      ""     -> current_secret
      nil    -> nil
      v      -> to_string(v)
    end
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp enabled_entries do
    %{rows: rows} =
      query!(Repo,
        """
        SELECT id, slug, display_name, host_match,
               authorization_endpoint, token_endpoint,
               scopes_default, client_id, client_secret,
               extra_auth_params, extra_token_params, enabled
        FROM oauth_catalog
        WHERE enabled = 1
        """,
        [])

    Enum.map(rows, &row_to_entry/1)
  end

  defp query_one(where, params) do
    case query!(Repo,
           """
           SELECT id, slug, display_name, host_match,
                  authorization_endpoint, token_endpoint,
                  scopes_default, client_id, client_secret,
                  extra_auth_params, extra_token_params, enabled
           FROM oauth_catalog
           #{where}
           LIMIT 1
           """,
           params) do
      %{rows: [row]} -> row_to_entry(row)
      _ -> nil
    end
  end

  defp row_to_entry([id, slug, display_name, host_match, auth_ep, token_ep,
                     scopes_json, client_id, client_secret,
                     extra_auth_json, extra_token_json, enabled]) do
    %{
      id:                     id,
      slug:                   slug,
      display_name:           display_name,
      host_match:             host_match,
      authorization_endpoint: auth_ep,
      token_endpoint:         token_ep,
      scopes_default:         decode_json_list(scopes_json),
      client_id:              client_id,
      client_secret:          client_secret,
      extra_auth_params:      decode_json_map(extra_auth_json),
      extra_token_params:     decode_json_map(extra_token_json),
      enabled:                enabled == 1
    }
  end

  defp decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_list(_), do: []

  defp decode_json_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_json_map(_), do: %{}

  # Extract host from either a bare host or a URL. Tolerates trailing
  # slash, query string, scheme-less inputs. Lowercased for the
  # suffix match.
  defp extract_host(input) do
    input
    |> String.trim()
    |> String.downcase()
    |> case do
      "https://" <> rest -> rest
      "http://" <> rest  -> rest
      other              -> other
    end
    |> String.split("/", parts: 2)
    |> List.first()
    |> case do
      nil -> ""
      h   -> String.split(h, ":") |> List.first() || ""
    end
  end
end
