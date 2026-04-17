# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Util.Html do
  @moduledoc """
  HTML → plain-text extraction using Floki.

  Shared cross-concern helper (web_fetch, web_search, proxy handler).
  Dumps all non-chrome content to a flat text stream. For structured
  article extraction (title, main body, byline), use
  `Dmhai.Web.ReaderExtractor` instead.
  """

  @skip_tags ~w(script style nav header footer aside noscript iframe svg button form meta link)

  @doc """
  Convert raw HTML bytes to plain text, stripping tags listed in @skip_tags.
  """
  @spec html_to_text(binary() | any()) :: String.t()
  def html_to_text(raw_bytes) when is_binary(raw_bytes) do
    html =
      case :unicode.characters_to_binary(raw_bytes, :utf8) do
        str when is_binary(str) -> str
        _ -> raw_bytes |> :binary.bin_to_list() |> List.to_string()
      end

    text =
      case Floki.parse_document(html) do
        {:ok, tree} ->
          tree
          |> remove_skip_tags()
          |> extract_text()
          |> Enum.join(" ")
          |> then(&Regex.replace(~r/\s+/, &1, " "))
          |> String.trim()

        {:error, _} ->
          ""
      end

    fix_digit_letter_spacing(text)
  end

  def html_to_text(_), do: ""

  # ── private ─────────────────────────────────────────────────────────────

  defp remove_skip_tags(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &remove_skip_tags/1)
  end

  defp remove_skip_tags({tag, _attrs, _children}) when tag in @skip_tags, do: []
  defp remove_skip_tags({tag, attrs, children}), do: [{tag, attrs, remove_skip_tags(children)}]
  defp remove_skip_tags(text) when is_binary(text), do: [text]
  defp remove_skip_tags(_), do: []

  defp extract_text(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &extract_text/1)
  end

  defp extract_text({_tag, _attrs, children}), do: extract_text(children)

  defp extract_text(text) when is_binary(text) do
    t = String.trim(text)
    if t == "", do: [], else: [t]
  end

  defp extract_text(_), do: []

  defp fix_digit_letter_spacing(text) do
    text
    |> then(&Regex.replace(~r/(\d)([A-Za-z])/, &1, "\\1 \\2"))
    |> then(&Regex.replace(~r/([A-Za-z])(\d)/, &1, "\\1 \\2"))
    |> then(&Regex.replace(~r/([a-z])([A-Z])/, &1, "\\1 \\2"))
  end
end
