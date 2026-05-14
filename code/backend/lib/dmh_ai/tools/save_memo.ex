# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.SaveMemo do
  @moduledoc """
  Save a personal fact the user stated for later recall via
  `fetch_memo`. Use only for STATEMENTS ("my X is Y"), never on
  questions. Dynamically gated — only present in the catalog on turns
  whose user message starts with `/memo`. See specs/commands.md.

  Strictly user-scoped: `user_id` comes from execution context, never
  from the model.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.UserAgent
  alias DmhAi.VectorDB

  @impl true
  def name, do: "save_memo"

  @impl true
  def description,
    do: "Save a personal fact the user has stated for later recall. Use only when the user is making a STATEMENT (\"my X is Y\"), never on questions."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        required: ["text"],
        properties: %{
          text: %{type: "string", description: "The fact to save, in the user's own words."}
        }
      }
    }
  end

  @impl true
  def execute(%{"text" => text}, ctx) when is_binary(text) and text != "" do
    user_id = ctx[:user_id] || ctx["user_id"]

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "save_memo requires authenticated user context"}

      true ->
        # Per specs/memo_encryption.md, memo chunks are AES-GCM
        # encrypted under a per-user MMK. `ensure_memo_key` is lazy:
        # if the user has no wrap on disk yet, it generates one
        # under the deployment master key and persists. Result is
        # cached in `UserAgent` state for subsequent calls.
        case UserAgent.ensure_memo_key(user_id) do
          {:ok, mmk} ->
            attrs = %{
              scope:       :memo,
              org_id:      DmhAi.Orgs.for_user(user_id),
              user_id:     user_id,
              source_kind: "text",
              source_ref:  sha256(text),
              title:       nil,
              memo_key:    mmk
            }

            case VectorDB.ingest(attrs, text) do
              {:ok, _info} -> {:ok, %{ok: true}}
              {:error, r}  -> {:error, "save_memo failed: #{inspect(r)}"}
            end

          {:error, reason} ->
            {:error, "save_memo failed: could not initialise memo key (#{inspect(reason)})"}
        end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: text"}

  defp sha256(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
end
