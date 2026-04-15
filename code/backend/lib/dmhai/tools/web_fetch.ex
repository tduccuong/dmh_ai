defmodule Dmhai.Tools.WebFetch do
  @behaviour Dmhai.Tools.Behaviour

  @max_chars 20_000
  @user_agent "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description, do: "Fetch and read the text content of any URL. HTML is stripped to plain text."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "The full URL to fetch (must start with http:// or https://)"}
        },
        required: ["url"]
      }
    }
  end

  @impl true
  def execute(%{"url" => url}, _context) do
    case Req.get(url,
           headers: [{"user-agent", @user_agent}],
           redirect: true,
           receive_timeout: 15_000,
           decode_body: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        text =
          body
          |> Dmhai.Html.html_to_text()
          |> String.slice(0, @max_chars)

        {:ok, %{url: url, content: text, truncated: byte_size(body) > @max_chars}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} fetching #{url}"}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: url"}
end
