# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Manifest do
  @moduledoc """
  Connector verb manifest — the contract Primitive 0.3 declares
  between the dispatcher and every connector module.

  Each connector implementation (`DmhAi.Connectors.<Name>`) must
  expose a single function:

      def manifest do
        %DmhAi.Tools.Manifest{
          connector: "hubspot",
          region:    "universal",
          verbs: %{
            "contact.find" => %DmhAi.Tools.Manifest.Verb{
              permission:    :read,
              callable_from: [:chat, :task],
              args:          %{
                "query" => %{type: :string, required: true}
              },
              errors:        [:unauthorised, :rate_limited]
            },
            "deal.create" => %DmhAi.Tools.Manifest.Verb{
              permission:      :write,
              callable_from:   [:task],
              idempotency_key: :required,
              args:            %{
                "contact_id" => %{type: :string, required: true},
                "amount"     => %{type: :number, required: true}
              },
              errors:          [:unauthorised, :duplicate, :rate_limited]
            }
          }
        }
      end

  The dispatcher validates this struct at boot. A verb with
  `permission: :write` MUST also have `callable_from: [:task]` and
  `idempotency_key: :required` — otherwise the connector fails to
  register and is logged as `manifest_violation`.
  """

  @enforce_keys [:connector, :region, :verbs]
  defstruct connector: nil, region: "universal", verbs: %{}

  defmodule Verb do
    @enforce_keys [:permission, :callable_from]
    defstruct permission:      nil,                    # :read | :write | :admin
              callable_from:   [:chat, :task],         # [:chat, :task] | [:task]
              idempotency_key: :none,                  # :required | :none
              args:            %{},                    # %{name => %{type, required}}
              returns:         %{},                    # informational
              errors:          [],                     # informational
              scopes:          []                      # OAuth scopes required
  end

  @doc """
  Validate a `Manifest` struct. Returns `:ok` or
  `{:error, {:manifest_violation, connector, reason}}`.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{connector: nil}),
    do: {:error, {:manifest_violation, nil, "connector name required"}}

  def validate(%__MODULE__{verbs: verbs}) when map_size(verbs) == 0,
    do: {:error, {:manifest_violation, "?", "no verbs declared"}}

  def validate(%__MODULE__{connector: name, verbs: verbs}) do
    Enum.reduce_while(verbs, :ok, fn {verb_name, verb}, _acc ->
      case validate_verb(verb_name, verb) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:manifest_violation, name, "#{verb_name}: #{reason}"}}}
      end
    end)
  end

  defp validate_verb(_name, %Verb{permission: :write} = v) do
    cond do
      not (:task in v.callable_from and length(v.callable_from) == 1) ->
        {:error,
         "write verb must declare `callable_from: [:task]` (HARD rule — got #{inspect(v.callable_from)})"}

      v.idempotency_key != :required ->
        {:error, "write verb must declare `idempotency_key: :required`"}

      true ->
        :ok
    end
  end

  defp validate_verb(_name, %Verb{permission: p})
       when p in [:read, :admin],
       do: :ok

  defp validate_verb(_name, %Verb{permission: p}),
    do: {:error, "unknown permission #{inspect(p)} (expected :read | :write | :admin)"}

  @type t :: %__MODULE__{
          connector: String.t() | nil,
          region: String.t(),
          verbs: %{optional(String.t()) => Verb.t()}
        }
end
