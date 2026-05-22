# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Mix.Tasks.Dump.Manifest do
  @moduledoc """
  Dev-time helper that serialises a connector module's
  `manifest/0` callback into the JSON shape consumed by
  `priv/connectors/<slug>/functions.json`. One-shot tool used while
  migrating each connector from code-side manifests to DB-backed
  storage — once migration finishes for all connectors this task is
  superseded by `mix discover.functions`.

  Usage:

      mix dump.manifest DmhAi.Connectors.HubSpot

  Writes `priv/connectors/<slug>/functions.json`.
  """

  use Mix.Task

  @shortdoc "Dump a connector module's manifest/0 to priv/connectors/<slug>/functions.json"

  @impl Mix.Task
  def run([mod_str]) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    mod = String.to_existing_atom("Elixir." <> mod_str)
    Code.ensure_loaded(mod)

    unless function_exported?(mod, :manifest, 0) do
      Mix.shell().error("#{mod_str} does not export manifest/0")
      System.halt(1)
    end

    m = mod.manifest()
    slug = m.connector

    rows =
      m.functions
      |> Enum.map(fn {name, f} -> normalise_function(name, f) end)

    out = %{
      "connector_slug"     => slug,
      "vendor_api_version" => "v3",
      "functions"          => rows
    }

    File.mkdir_p!("priv/connectors/#{slug}")
    path = "priv/connectors/#{slug}/functions.json"
    File.write!(path, Jason.encode!(out, pretty: true))
    Mix.shell().info("wrote #{path} — #{length(rows)} functions")
  end

  def run(_), do: Mix.shell().error("usage: mix dump.manifest <ConnectorModule>")

  defp normalise_function(name, %DmhAi.Tools.Manifest.Function{} = f) do
    %{
      "function_name"        => name,
      "permission"           => to_string(f.permission),
      "args"                 => normalise_args(f.args),
      "returns"              => f.returns |> Enum.into(%{}, fn {k, v} -> {to_string(k), to_string(v)} end),
      "error_classes"        => Enum.map(f.errors || [], &to_string/1),
      "scopes_required"      => f.scopes || [],
      "idempotency_key"      => to_string(f.idempotency_key || :none),
      "callable_from"        => Enum.map(f.callable_from || [], &to_string/1),
      "poll_trigger_capable" => f.poll_trigger_capable || false,
      "cursor_arg"           => f.cursor_arg,
      "cursor_response_path" => f.cursor_response_path,
      "items_path"           => f.items_path,
      "min_poll_seconds"     => f.min_poll_seconds,
      "default_poll_seconds" => f.default_poll_seconds
    }
    |> compact()
  end

  defp normalise_args(args) when is_map(args) do
    args
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), normalise_arg(v)} end)
  end

  defp normalise_arg(%{} = meta) do
    meta
    |> Enum.map(fn
      {:type, atom} when is_atom(atom) and not is_boolean(atom) ->
        {"type", to_string(atom)}

      {:provenance, %{} = p} ->
        {"provenance", normalise_provenance(p)}

      {:format, atom} when is_atom(atom) and not is_boolean(atom) ->
        {"format", to_string(atom)}

      {key, val} when is_atom(key) ->
        {to_string(key), encode_value(val)}

      {key, val} ->
        {to_string(key), encode_value(val)}
    end)
    |> Enum.into(%{})
  end

  defp normalise_provenance(%{} = p) do
    p
    |> Enum.map(fn
      {:kind, atom} -> {"kind", to_string(atom)}
      {key, val} when is_atom(key) -> {to_string(key), encode_value(val)}
      {key, val} -> {to_string(key), encode_value(val)}
    end)
    |> Enum.into(%{})
  end

  # Preserve booleans + numbers + strings as themselves; serialise
  # non-boolean atoms to strings (e.g. `:string` → `"string"`).
  defp encode_value(v) when is_boolean(v), do: v
  defp encode_value(v) when is_atom(v) and not is_nil(v), do: to_string(v)
  defp encode_value(v), do: v

  defp compact(m) do
    Enum.reject(m, fn {_k, v} -> is_nil(v) end) |> Enum.into(%{})
  end
end
