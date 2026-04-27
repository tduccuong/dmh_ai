# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.RequestInput do
  @moduledoc """
  Generic agentic primitive: ask the user for structured input via an
  in-chat form (text / password fields).

  Chain-terminating: when emitted, the chain loop captures the model's
  preceding narration, persists a single assistant message carrying the
  form spec, and ends the chain. The user's submission flows back as a
  synthesised user-role message that auto-resumes the chain.

  See architecture.md §In-chain structured input — `request_input`.
  """

  @behaviour Dmhai.Tools.Behaviour

  @impl true
  def name, do: "request_input"

  @impl true
  def description do
    """
    Render an inline form to collect STRUCTURED, NAMED values (API key, client_id + client_secret, multi-field config). Each field: `{name, label, type: "text"|"password", secret?}` — `password` auto-implies `secret: true`. Optional `submit_label` (default "Submit"); narration text emitted with the call is shown above the form.

    Chain-terminating: don't pair with other tool calls. The user's submission flows back as a user-role message that resumes the chain.

    NOT for open-ended questions ("how should we proceed?") — those go in plain text.
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          fields: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                name:   %{type: "string", description: "Programmatic key the value comes back under."},
                label: %{type: "string", description: "Human-readable label shown above the input."},
                type:  %{type: "string", enum: ["text", "password"], description: "'text' for plain inputs, 'password' for masked + secret-treatment."},
                secret: %{type: "boolean", description: "Force secret treatment regardless of type. Defaults to true when type='password'."}
              },
              required: ["name", "label", "type"]
            },
            description: "Ordered list of fields the form will render."
          },
          submit_label: %{
            type: "string",
            description: "Optional submit button label; defaults to 'Submit'."
          }
        },
        required: ["fields"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)

    with :ok                <- require_ctx(user_id, session_id),
         {:ok, fields}      <- normalise_fields(Map.get(args, "fields")) do
      token       = mint_token()
      ttl_secs    = Dmhai.Agent.AgentSettings.request_input_ttl_secs()
      expires_at  = System.os_time(:millisecond) + ttl_secs * 1_000

      submit_label =
        case Map.get(args, "submit_label") do
          s when is_binary(s) and s != "" -> s
          _                                 -> "Submit"
        end

      form = %{
        token:        token,
        fields:       fields,
        submit_label: submit_label,
        expires_at:   expires_at,
        submitted:    false,
        submitted_at: nil,
        values_meta:  nil
      }

      # The chain loop reads this from the tool result and stamps the
      # `form` field onto the just-persisted assistant message. See
      # `Dmhai.Agent.UserAgent.session_chain_loop`.
      {:ok, %{token: token, expires_at: expires_at, form: form}}
    end
  end

  # ── private ────────────────────────────────────────────────────────────

  defp require_ctx(nil, _), do: {:error, "request_input called without user_id in context"}
  defp require_ctx(_, nil), do: {:error, "request_input called without session_id in context"}
  defp require_ctx(_, _),    do: :ok

  defp normalise_fields(list) when is_list(list) and list != [] do
    list
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case normalise_field(raw) do
        {:ok, f}            -> {:cont, {:ok, [f | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rev}  -> {:ok, Enum.reverse(rev)}
      other        -> other
    end
  end

  defp normalise_fields(_), do: {:error, "request_input requires `fields` to be a non-empty array"}

  defp normalise_field(%{} = raw) do
    name  = Map.get(raw, "name")  |> to_str_or_nil()
    label = Map.get(raw, "label") |> to_str_or_nil()
    type  = Map.get(raw, "type")  |> to_str_or_nil()
    raw_secret = Map.get(raw, "secret")

    cond do
      not (is_binary(name)  and name  != "") -> {:error, "field is missing `name`"}
      not (is_binary(label) and label != "") -> {:error, "field `#{name}` is missing `label`"}
      type not in ["text", "password"]        -> {:error, "field `#{name}` has invalid `type` (must be 'text' or 'password')"}
      true ->
        # Password type implies secret unless caller said otherwise.
        secret =
          case raw_secret do
            true  -> true
            false -> false
            _      -> type == "password"
          end

        {:ok, %{name: name, label: label, type: type, secret: secret}}
    end
  end

  defp normalise_field(_), do: {:error, "field must be an object"}

  defp to_str_or_nil(nil),              do: nil
  defp to_str_or_nil(s) when is_binary(s), do: s
  defp to_str_or_nil(_),                  do: nil

  defp mint_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
