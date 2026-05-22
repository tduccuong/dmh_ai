# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Discoverable do
  @moduledoc """
  Behaviour implemented by every connector that wants to refresh its
  catalogue from the live vendor. The admin External Connectors page
  shows one **Discover <Layer>** button per implemented callback;
  each click triggers a background `Connectors.Discovery` run that
  persists the result to the DB.

  Three layers, all optional — a connector implements the ones the
  vendor exposes:

  * `discover_functions/0` — Layer A. Returns the function catalogue:
    one row per `<slug>.<function>`, with arg + provenance + returns +
    error classes + scopes. Source can be the vendor's OpenAPI spec,
    an MCP `tools/list` probe, or the bundled `priv/connectors/<slug>/
    functions.json` seed payload as a fallback.

  * `discover_metadata_sample/2` — Layer B. Probes ONE vendor metadata
    path (e.g. `crm.contacts.properties`) for the given user and
    returns the schema. Cached per-user in `connector_vendor_metadata`.
    The model triggers a per-property fetch lazily via
    `inspect_function_property`; this callback is for the admin
    sanity-check button only.

  * `discover_docs/0` — Layer C. Returns the URL list the wiki crawler
    should ingest (vendor docs, API reference, tutorials). Each URL
    is added to the KB sources table; the crawl itself is the
    existing wiki indexing pipeline.

  Discoverable callbacks must be SIDE-EFFECT-FREE w.r.t. DB state —
  they return raw rows and the `Connectors.Discovery` runner owns the
  `Manifest.replace_all/3` atomic-swap. This keeps the contract
  testable in isolation and gives the runner exclusive write authority
  to `connector_functions`.
  """

  @typedoc """
  One function row, normalised to the shape `Manifest.replace_all/3`
  expects. Same keys as `Connectors.Seed`'s `normalise_row/1` output.
  """
  @type function_row :: %{
          function_name:        String.t(),
          permission:           atom(),
          args:                 map(),
          returns:              map(),
          error_classes:        [atom() | String.t()],
          scopes_required:      [String.t()],
          idempotency_key:      atom(),
          callable_from:        [atom()],
          poll_trigger_capable: boolean(),
          cursor_arg:           String.t() | nil,
          cursor_response_path: String.t() | nil,
          items_path:           String.t() | nil,
          min_poll_seconds:     non_neg_integer() | nil,
          default_poll_seconds: non_neg_integer() | nil,
          vendor_endpoint_hint: String.t() | nil
        }

  @type metadata_sample :: %{
          schema:     map(),
          expires_at: integer() | nil
        }

  @type doc_source :: %{url: String.t()}

  @callback discover_functions() :: {:ok, [function_row()]} | {:error, term()}
  @callback discover_metadata_sample(user_id :: String.t(), path :: String.t()) ::
              {:ok, metadata_sample()} | {:error, term()}
  @callback discover_docs() :: {:ok, [doc_source()]} | {:error, term()}

  @optional_callbacks [
    discover_functions: 0,
    discover_metadata_sample: 2,
    discover_docs: 0
  ]

  @doc """
  Whether a connector module implements a given layer's callback. Used
  by the admin handler to decide which Discover buttons to render.
  """
  @spec implements?(module(), :functions | :metadata | :docs) :: boolean()
  def implements?(mod, :functions),  do: function_exported?(mod, :discover_functions, 0)
  def implements?(mod, :metadata),   do: function_exported?(mod, :discover_metadata_sample, 2)
  def implements?(mod, :docs),       do: function_exported?(mod, :discover_docs, 0)
end
