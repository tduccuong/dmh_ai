# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Calculator do
  @behaviour Dmhai.Tools.Behaviour

  @impl true
  def name, do: "calculator"

  @impl true
  def description, do: "Evaluate a math expression (arithmetic, trig, log, complex; constants: pi, e)."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          expression: %{type: "string", description: "Expression to evaluate, e.g. 'sqrt(2)', 'sin(pi/4)'."}
        },
        required: ["expression"]
      }
    }
  end

  @impl true
  def execute(%{"expression" => expr}, _context) do
    # JSON-encode the expression to safely embed it as a Python string literal.
    # Restrict builtins to {} and expose only math/cmath public symbols — no import, no exec, no open.
    encoded = Jason.encode!(expr)

    script = """
    import math, cmath
    safe = {k: getattr(math, k) for k in dir(math) if not k.startswith('_')}
    safe.update({k: getattr(cmath, k) for k in dir(cmath) if not k.startswith('_')})
    try:
        result = eval(#{encoded}, {"__builtins__": {}}, safe)
        print(result)
    except Exception as e:
        print("ERROR:", e)
    """

    case System.cmd("python3", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        output = String.trim(output)

        if String.starts_with?(output, "ERROR:") do
          {:error, String.replace_prefix(output, "ERROR: ", "")}
        else
          {:ok, %{expression: expr, result: output}}
        end

      {output, _} ->
        {:error, String.trim(output)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(_, _), do: {:error, "Missing required argument: expression"}
end
