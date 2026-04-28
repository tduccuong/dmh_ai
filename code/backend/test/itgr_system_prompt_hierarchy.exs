# Integration tests: system-prompt heading hierarchy coherence.
# Run with: MIX_ENV=test mix test test/itgr_system_prompt_hierarchy.exs
#
# These prompts get concatenated with other blocks (Today's date, profile
# section, task list, recently-extracted files) at context-build time.
# A badly-leveled heading in assistant_base or confidant_base poisons
# the whole assembled message. Assert structural invariants.

defmodule Itgr.SystemPromptHierarchy do
  use ExUnit.Case, async: true

  alias Dmhai.Agent.SystemPrompt

  # Extract heading depths (# count) in document order from a markdown string.
  defp heading_depths(text) do
    ~r/^(#+)\s/m
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.length/1)
  end

  # A hierarchy is coherent when no transition skips a level going DEEPER.
  # Going shallower (any amount) is fine. h2→h3 ok, h2→h4 not ok, h4→h2 ok.
  defp coherent?(depths) do
    depths
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b <= a + 1 end)
  end

  # ─── Assistant (v2.5 — XML-tag structure) ───────────────────────────────
  #
  # The assistant prompt was rewritten in v2.5 to use XML tags instead
  # of markdown headings. Hierarchy / depth checks no longer apply;
  # we instead pin the canonical tag set + their order, plus the
  # attachment-tree ordering inside `<attachments>`.

  test "assistant: prompt starts with the <system_purpose> tag" do
    prompt = SystemPrompt.generate_assistant([])
    leading = prompt |> String.trim_leading() |> String.slice(0, 32)

    assert String.starts_with?(leading, "<system_purpose>"),
           "expected prompt to lead with <system_purpose>, got: #{inspect(leading)}"
  end

  # Canonical section-opener tags. Some of these names also appear
  # mid-prose as inline references (e.g. `<intent_matrix>` is mentioned
  # in `<reasoning_protocol>`); we match the section-opener form
  # `<tag>\n` so a textual reference doesn't fool the position check.
  @canonical_tags [
    "system_purpose",
    "primitives",
    "reasoning_protocol",
    "hard_constraints",
    "intent_matrix",
    "task_completion",
    "pivot_rule",
    "knowledge_chitchat",
    "resuming_task",
    "periodic_tasks",
    "focus_rule",
    "verbs",
    "context_blocks",
    "tool_selection",
    "external_apis",
    "credentials",
    "request_input",
    "attachments",
    "connect_mcp",
    "ssh",
    "output_formatting",
    "language",
    "voice"
  ]

  test "assistant: canonical XML section openers are present and in order" do
    prompt = SystemPrompt.generate_assistant([])

    indices =
      Enum.map(@canonical_tags, fn tag ->
        opener = "<#{tag}>\n"
        idx = :binary.match(prompt, opener)
        refute idx == :nomatch, "missing section opener: #{opener}"
        elem(idx, 0)
      end)

    assert indices == Enum.sort(indices),
           "tag order drifted: #{inspect(@canonical_tags)} → positions #{inspect(indices)}"
  end

  test "assistant: every canonical section opener has a matching closer" do
    prompt = SystemPrompt.generate_assistant([])

    Enum.each(@canonical_tags, fn tag ->
      assert String.contains?(prompt, "</#{tag}>"),
             "section <#{tag}> has no closing </#{tag}>"
    end)
  end

  test "assistant: profile section appends cleanly when provided" do
    without = SystemPrompt.generate_assistant([])
    with_profile = SystemPrompt.generate_assistant(profile: "Alice, VN, loves jazz.")
    assert byte_size(with_profile) > byte_size(without)
  end

  # ─── Attachments decision tree — step ordering ──────────────────────────

  # The bare-📎 follow-up decision tree must put "check Recently-extracted
  # first" ABOVE the re-extract / gist branches. If the order drifts the
  # model re-extracts files that are already in context (regression we hit
  # with gemini-3-flash in session 1776956365474). Lock the order in.
  #
  # In v2.5 the decision tree lives inside `<attachments>` as a numbered
  # "first match wins" list. Test pins the relative positions of the
  # three branches inside that tag.
  test "assistant: <attachments> decision tree puts Recently-extracted check before the re-extract branches" do
    prompt = SystemPrompt.generate_assistant([])

    recently_extracted_check = :binary.match(prompt, "File appears in `## Recently-extracted files`")
    re_extract_branch        = :binary.match(prompt, "Re-extract needed")
    gist_branch              = :binary.match(prompt, "Gist-level follow-up")
    first_match_marker       = :binary.match(prompt, "first match wins")

    refute recently_extracted_check == :nomatch, "Recently-extracted check missing from the Attachments tree"
    refute re_extract_branch == :nomatch,        "Re-extract branch missing"
    refute gist_branch == :nomatch,              "Gist-level branch missing"
    refute first_match_marker == :nomatch,       "Missing 'first match wins' marker — without it, ordering is decorative"

    {re_pos, _}        = recently_extracted_check
    {re_extract_pos, _} = re_extract_branch
    {gist_pos, _}      = gist_branch

    assert re_pos < re_extract_pos,
           "Recently-extracted check must appear BEFORE Re-extract branch"
    assert re_pos < gist_pos,
           "Recently-extracted check must appear BEFORE Gist-level branch"
  end

  # ─── Confidant ────────────────────────────────────────────────────────────

  test "confidant: heading hierarchy is coherent" do
    prompt = SystemPrompt.generate_confidant([])
    assert coherent?(heading_depths(prompt))
  end

  test "confidant: extra sections (image/video/profile) don't break hierarchy" do
    prompt =
      SystemPrompt.generate_confidant(
        profile: "Bob",
        has_video: true,
        image_descriptions: [%{name: "a.jpg", description: "a cat"}],
        video_descriptions: [%{name: "b.mp4", description: "a demo"}]
      )

    assert coherent?(heading_depths(prompt))
  end
end
