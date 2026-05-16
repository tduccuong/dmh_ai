# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Manifest do
  @moduledoc """
  Connector function manifest — the contract Primitive 0.3 declares
  between the dispatcher and every connector module.

  Each connector implementation (`DmhAi.Connectors.<Name>`) must
  expose a single function:

      def manifest do
        %DmhAi.Tools.Manifest{
          connector: "hubspot",
          region:    "universal",
          functions: %{
            "contact.find" => %DmhAi.Tools.Manifest.Function{
              permission:    :read,
              callable_from: [:chat, :task],
              args:          %{
                "query" => %{type: :string, required: true}
              },
              errors:        [:unauthorised, :rate_limited]
            },
            "deal.create" => %DmhAi.Tools.Manifest.Function{
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

  The dispatcher validates this struct at boot. A function with
  `permission: :write` MUST also have `callable_from: [:task]` and
  `idempotency_key: :required` — otherwise the connector fails to
  register and is logged as `manifest_violation`.
  """

  @enforce_keys [:connector, :region, :functions]
  defstruct connector: nil, region: "universal", functions: %{}

  defmodule Function do
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

  def validate(%__MODULE__{functions: functions}) when map_size(functions) == 0,
    do: {:error, {:manifest_violation, "?", "no functions declared"}}

  def validate(%__MODULE__{connector: name, functions: functions}) do
    Enum.reduce_while(functions, :ok, fn {function_name, function}, _acc ->
      case validate_function(function_name, function) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:manifest_violation, name, "#{function_name}: #{reason}"}}}
      end
    end)
  end

  defp validate_function(_name, %Function{permission: :write} = f) do
    cond do
      not (:task in f.callable_from and length(f.callable_from) == 1) ->
        {:error,
         "write function must declare `callable_from: [:task]` (HARD rule — got #{inspect(f.callable_from)})"}

      f.idempotency_key != :required ->
        {:error, "write function must declare `idempotency_key: :required`"}

      true ->
        :ok
    end
  end

  defp validate_function(_name, %Function{permission: p})
       when p in [:read, :admin],
       do: :ok

  defp validate_function(_name, %Function{permission: p}),
    do: {:error, "unknown permission #{inspect(p)} (expected :read | :write | :admin)"}

  @type t :: %__MODULE__{
          connector: String.t() | nil,
          region: String.t(),
          functions: %{optional(String.t()) => Function.t()}
        }
end
