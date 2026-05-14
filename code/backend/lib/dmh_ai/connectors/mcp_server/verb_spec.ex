# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer.VerbSpec do
  @moduledoc """
  Declarative spec for one MCP-callable verb on top of a vendor REST
  API. The generic `MCPServer.RestBridge` reads a `%VerbSpec{}` and
  executes the call, including OAuth bearer-token forwarding and
  error normalisation. Per-connector modules supply a `%{verb_name
  => %VerbSpec{}}` map; everything else (HTTP, JSON, retry, error
  classification) is shared.

  ## Fields

    * `:method` — `:get | :post | :patch | :delete | :put`
    * `:url` — full URL string OR a function `(args -> url)`. Use a
      function for URLs with path params: `fn %{"id" => id} ->
      "https://api.example/items/\#{id}" end`.
    * `:request` — optional transform `(args, ctx) -> req_opts`.
      Maps the MCP-side args to Req's call options (`:json`,
      `:body`, `:query`, `:multipart`, `:headers`). Default behaviour:
      `:get` / `:delete` puts `args` into `:query`; `:post` /
      `:patch` / `:put` puts `args` into `:json`. The default
      covers 80% of REST verbs; override for verbs that need MIME
      composition, multipart bodies, etc.
    * `:response` — optional transform `(status, body) -> {:ok,
      map} | {:error, atom}`. Default behaviour: 2xx → `{:ok,
      body}` (or `{:ok, %{"text" => body}}` for non-map bodies);
      4xx/5xx → `{:error, MCPServer.ErrorMap.classify(status, body)}`.
      Override for verbs that need to reshape a 2xx body (e.g.
      `gcal.find_free_slots` computes free slots from busy
      intervals).
    * `:doc` — optional one-line description used by the
      `tools/list` response.

  ## Construction

      %VerbSpec{
        method: :get,
        url: "https://gmail.googleapis.com/gmail/v1/users/me/messages",
        request: fn args, _ctx ->
          %{query: %{"q" => args["query"], "maxResults" => args["limit"] || 25}}
        end,
        response: fn 200, %{"messages" => msgs} -> {:ok, %{"messages" => msgs}} end,
        doc: "List Gmail messages matching the query"
      }

  ## Why a struct and not a behaviour

  A struct lets the per-connector module emit the spec as data
  (one `%VerbSpec{}` literal per verb, often 5–15 lines). A
  behaviour would force one callback per verb — fine for 6 verbs
  but awkward when a connector grows to 20. The struct shape
  composes naturally with `Enum.into` / `Map.merge` so a future
  "common verbs" library (e.g. CRUD primitives) can mix in.
  """

  defstruct [
    :method,
    :url,
    :request,
    :response,
    :handler,
    :doc,
    scopes_required: []
  ]

  @type method :: :get | :post | :patch | :delete | :put
  @type url   :: String.t() | (map() -> String.t())
  @type request_fn  :: (map(), map() -> keyword() | map())
  @type response_fn :: (non_neg_integer(), term() -> {:ok, term()} | {:error, atom()})

  @typedoc """
  Custom verb handler for verbs that don't fit the one-HTTP-call
  shape. Receives `(args, ctx)` and returns the same `{:ok, term}`
  / `{:error, atom}` shape the bridge produces.

  When `:handler` is set on a `%VerbSpec{}`, `RestBridge.invoke/3`
  calls it directly and ignores `:method`, `:url`, `:request`, and
  `:response` — the handler has full control. Used for verbs like
  Gmail's search-then-fetch-headers fan-out, where one MCP verb
  corresponds to multiple vendor API calls.

  Implementations typically call back into `RestBridge.invoke/3`
  for the sub-calls so error handling + bearer forwarding stay
  consistent.
  """
  @type handler_fn :: (map(), map() -> {:ok, term()} | {:error, atom()})

  @type t :: %__MODULE__{
          method:           method() | nil,
          url:              url() | nil,
          request:          request_fn() | nil,
          response:         response_fn() | nil,
          handler:          handler_fn() | nil,
          doc:              String.t() | nil,
          scopes_required:  [String.t()]
        }
end
