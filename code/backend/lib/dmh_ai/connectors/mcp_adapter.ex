# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPAdapter do
  @moduledoc """
  Base behaviour for Case-B connector adapters per Primitive 0.3.

  Every external SaaS connector (HubSpot, M365, Google Workspace,
  Stripe, …) is a thin module that `use`s this behaviour and
  supplies three callbacks:

      @callback manifest() :: DmhAi.Tools.Manifest.t()
      @callback mcp_slug() :: String.t()              # row in mcp_catalog
      @callback remap_error(term()) :: term()         # vendor → canonical vocab

  The `__using__` macro wires a default `call/3` that:

    1. Resolves the calling user's `user_credentials` for
       `mcp_slug()`. Missing → returns the canonical
       `missing_credentials` envelope.
    2. Invokes the upstream MCP tool via
       `DmhAi.Connectors.MCPAdapter.Caller.invoke/4`. (The Caller
       module is the bridge to the existing `DmhAi.MCP.Registry`
       plumbing — kept separate so per-connector modules don't
       carry network code.)
    3. Pipes the response through the connector's `remap_error/1`
       and the canonical error normaliser
       (`DmhAi.Connectors.MCPAdapter.ErrorNormalizer.normalize/1`).
    4. Writes the audit-log row via
       `DmhAi.Connectors.MCPAdapter.Audit.record/4` (read = silent;
       write = always logged).

  Per-connector modules typically end up under 100 LoC each —
  manifest, slug, error remap, and any function-specific arg massaging.
  All cross-cutting code lives here / in the three sibling helpers.
  """

  alias DmhAi.Connectors.MCPAdapter.{Audit, Caller, ErrorNormalizer}
  alias DmhAi.Tools.Manifest

  @doc "Returns the connector's function manifest."
  @callback manifest() :: Manifest.t()

  @doc "The connector's slug as registered in `mcp_catalog`."
  @callback mcp_slug() :: String.t()

  @doc """
  Map a vendor-specific error term to the canonical vocabulary
  (`:unauthorised | :not_found | :rate_limited | :duplicate |
  :upstream_5xx`) or `:passthrough` to defer to the generic
  normaliser. Optional — defaults to `:passthrough`.
  """
  @callback remap_error(term()) :: atom() | :passthrough

  @doc """
  Which credential kind this connector stores in `user_credentials`.
  Defaults to `:oauth2` (the dominant Universal-Region pattern); API
  key connectors (Stripe, Klaviyo, Brevo) override to `:api_key`.
  The `MCPAdapter.Caller` reads this to pick the right
  `user_credentials.target` prefix (`oauth:<slug>` vs `api_key:<slug>`).
  """
  @callback credential_kind() :: :oauth2 | :api_key

  @doc """
  Primitive 0.9 hook — describes the vendor function that maps an
  email (the pivot from DMH-AI's `users.email`) to the vendor's
  native user identifier. The compiler injects a probe step around
  this function whenever a workflow references `@user_N` against
  this connector.

  Return shape:

      %{
        function:   "<slug>.<function_path>",   # canonical name in Tools.Catalog
        by_arg:     :email,                      # arg name receiving the email
        emit_field: "external_id"                # which emit field holds the vendor id
      }

  Return `nil` when the connector has no usable email-pivot
  function. Workflows that name `@user_N` against a nil-lookup
  connector fail at compile time with `unmappable_identity`; the
  user picks a remediation (manual override row, drop the step,
  use a literal external_id in source prose).
  """
  @callback identity_lookup() :: %{function: String.t(), by_arg: atom(), emit_field: String.t()} | nil

  @doc """
  Compile-time property introspection (Layer W L2). The compiler
  calls this when the user names a deep property of a vendor-rich
  object — e.g. `dealstage` on a HubSpot deal, `recurrence` on a
  Google Calendar event. The connector either resolves the property
  from its manifest, OR fetches the user's vendor metadata at call
  time (the user is online; their token is fresh).

  Arguments:
    * `function_name` — bare name (e.g. `"deal.create"`).
    * `path`          — dotted path into the property (e.g.
                        `"dealstage"`, `"recurrence.frequency"`).
    * `ctx`           — `%{user_id, org_id}` so the connector can
                        look up the user's vendor credentials when
                        the source is `:vendor_metadata`.

  Return shape (success):
      {:ok, %{
        type:        "<type>",
        enum:        ["<v>", ...] | nil,
        description: "<text>",
        source:      :manifest | :vendor_metadata
      }}

  Return `{:error, :not_supported}` when the connector hasn't
  implemented property introspection for that path. The compiler
  treats `:not_supported` as "trust the literal" and proceeds —
  this callback is purely additive.
  """
  @callback inspect_property(String.t(), String.t(), map()) ::
              {:ok, %{
                 type:        String.t(),
                 enum:        [String.t()] | nil,
                 description: String.t() | nil,
                 source:      :manifest | :vendor_metadata
               }}
              | {:error, atom()}

  @optional_callbacks remap_error: 1, credential_kind: 0, identity_lookup: 0,
                      inspect_property: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour DmhAi.Connectors.MCPAdapter

      # Default `call/3` — Dispatcher invokes this once the 4 rule
      # gates have passed. Concrete connectors only need
      # `manifest/0`, `mcp_slug/0`, and (optionally) `remap_error/1`.
      def call(function_name, args, caller_ctx) do
        DmhAi.Connectors.MCPAdapter.dispatch(__MODULE__, function_name, args, caller_ctx)
      end

      # Default error remap — defer to the generic normaliser.
      def remap_error(_), do: :passthrough

      # Default credential kind — OAuth2. API-key connectors
      # override.
      def credential_kind, do: :oauth2

      # Default property introspection — connector hasn't wired
      # vendor-metadata lookup. Compiler treats this as "trust
      # the literal" and proceeds.
      def inspect_property(_function_name, _path, _ctx),
        do: {:error, :not_supported}

      defoverridable remap_error: 1, credential_kind: 0, inspect_property: 3
    end
  end

  @doc """
  Shared entry point used by the generated `call/3`. Pulled out as
  a public function so test stubs can call it directly without the
  `use` macro.
  """
  @spec dispatch(module(), String.t(), map(), map()) ::
          {:ok, term()} | {:error, map()}
  def dispatch(connector_mod, function_name, args, caller_ctx) do
    slug = connector_mod.mcp_slug()
    kind = connector_mod.credential_kind()

    with {:ok, creds} <- Caller.lookup_credentials(slug, caller_ctx, kind),
         {:ok, raw}   <- Caller.invoke(slug, function_name, args, creds, caller_ctx) do
      result = normalise_result(connector_mod, raw)

      Audit.record(connector_mod, function_name, caller_ctx, audit_outcome(result))
      result
    else
      {:error, :missing_credentials} ->
        envelope = %{error: "missing_credentials", connector: slug}
        Audit.record(connector_mod, function_name, caller_ctx, {:denied, "missing_credentials"})
        {:error, envelope}

      {:error, reason} ->
        envelope = ErrorNormalizer.normalize(reason, fn r -> connector_mod.remap_error(r) end)
        Audit.record(connector_mod, function_name, caller_ctx,
                     {:denied, envelope[:error] || "upstream_error"})
        {:error, envelope}
    end
  rescue
    e ->
      require Logger
      Logger.error("[MCPAdapter] dispatch crashed: #{Exception.message(e)}")
      {:error, %{error: "adapter_crash", reason: Exception.message(e)}}
  end

  defp normalise_result(_connector_mod, raw) do
    # The Caller already returns `{:ok, vendor_result}` on success
    # (we only get here on the `:ok` branch). Pass through; the
    # adapter shim is for ERROR normalisation, which lives in the
    # `else` branch above.
    {:ok, raw}
  end

  defp audit_outcome({:ok, _}), do: :allowed
  defp audit_outcome(_), do: {:denied, "unknown"}
end
