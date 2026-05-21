# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.MalformedArgumentsError do
  @moduledoc """
  Raised when a tool-call's `function.arguments` string fails to parse
  as a JSON object. Carries the raw string and the decode error so the
  operator can tell from logs whether the failure came from the model
  or from the harness's streaming accumulator.

  Caught at the chain boundary; surfaced as an honest internal error
  to the user. Never silently degraded — a silent degrade routes blame
  downstream and burns retries on a corrupt input the model can't fix.
  """

  defexception [:raw, :decode_error]

  @impl true
  def message(%__MODULE__{raw: raw, decode_error: err}) do
    "tool_call.arguments did not parse as a JSON object. " <>
      "decode_error=#{inspect(err)} raw=#{inspect(String.slice(raw || "", 0, 500))}"
  end
end
