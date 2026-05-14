# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.KbQuery do
  @moduledoc """
  HTTP-level KB query (partial Primitive 0.6 — REST API surface).

  Route (declared in `DmhAi.Router`):

      POST /kb/query
        auth: bearer (any authenticated user)
        body: { "q": "search phrase", "limit": 10 (optional) }
        → { "hits": [ { source, source_kind, text, score, score_rounded } ] }

  Org-scoping is automatic: the caller's `org_id` (resolved via
  `Orgs.for_user/1`) bounds the `VectorDB.search` filter. A user can
  only see hits from their own org's KB. Cross-org isolation is the
  test contract verified by `test/flows/F35_cross_org_isolation.exs`.

  Same data path as the `fetch_index` tool the agent uses internally
  — both resolve through `VectorDB.search(:knowledge, _, _, _,
  {:org, org_id})`. This endpoint exposes the same path to external
  callers (and to e2e tests) without needing to go through a chat
  turn.

  ## Status

  Spec'd in Primitive 0.6 (REST API surface) but landed early to
  unblock the F34/F35 e2e tests for Primitive 0.1's org-scoping
  guarantee. The eventual public `/api/v1/kb/query` endpoint
  (per Primitive 0.6) will be a thin alias of this.
  """

  import Plug.Conn

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Orgs
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder

  @spec query(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def query(conn, user) do
    with {:ok, body} <- read_json_body(conn),
         {:ok, q}    <- fetch_query(body),
         {:ok, vec}  <- Embedder.embed(q) do
      org_id = Orgs.for_user(user.id)
      limit  = (is_integer(body["limit"]) && body["limit"]) || AgentSettings.kb_top_n()

      case VectorDB.search(:knowledge, q, vec, limit, {:org, org_id}) do
        {:ok, hits} ->
          json(conn, 200, %{hits: format(hits)})

        {:error, reason} ->
          json(conn, 500, %{error: "kb_query failed: #{inspect(reason)}"})
      end
    else
      {:error, :missing_q}     -> json(conn, 400, %{error: "missing q"})
      {:error, :bad_body}      -> json(conn, 400, %{error: "invalid JSON body"})
      {:error, reason}         -> json(conn, 500, %{error: "embed failed: #{inspect(reason)}"})
    end
  end

  defp fetch_query(%{"q" => q}) when is_binary(q) and q != "", do: {:ok, q}
  defp fetch_query(_), do: {:error, :missing_q}

  defp read_json_body(conn) do
    case read_body(conn) do
      {:ok, "", _}   -> {:ok, %{}}
      {:ok, body, _} ->
        try do
          {:ok, Jason.decode!(body)}
        rescue
          _ -> {:error, :bad_body}
        end
      _ -> {:error, :bad_body}
    end
  end

  defp format(hits) do
    Enum.map(hits, fn h ->
      %{
        source:      "#{h.source_kind}:#{h.source_id}",
        source_kind: h.source_kind,
        source_id:   h.source_id,
        text:        h.chunk_text,
        score:       h.score
      }
    end)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
