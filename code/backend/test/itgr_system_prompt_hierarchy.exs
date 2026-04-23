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

  # ─── Assistant ────────────────────────────────────────────────────────────

  test "assistant: full prompt starts at h2 (no orphan h1)" do
    prompt = SystemPrompt.generate_assistant([])
    [first | _] = heading_depths(prompt)
    assert first == 2
  end

  test "assistant: heading hierarchy is coherent (no level skips deeper)" do
    prompt = SystemPrompt.generate_assistant([])
    depths = heading_depths(prompt)
    assert coherent?(depths),
           "heading depth transitions skipped a level: #{inspect(depths)}"
  end

  test "assistant: heading depths are bounded to h2 and h3 only in the base prompt" do
    # Base assistant prompt has only ## and ### — h1 would clash with any
    # h1 in the pipeline, h4+ would visually flatten with the task-list
    # block's own h4 rows (#### `task_id` — title).
    prompt = SystemPrompt.generate_assistant([])
    assert Enum.all?(heading_depths(prompt), &(&1 in [2, 3])),
           "base assistant prompt should only use ## and ###, got: #{inspect(heading_depths(prompt))}"
  end

  test "assistant: profile section appends cleanly when provided" do
    without = SystemPrompt.generate_assistant([])
    with_profile = SystemPrompt.generate_assistant(profile: "Alice, VN, loves jazz.")
    assert byte_size(with_profile) > byte_size(without)
    # Profile addition preserves hierarchy coherence.
    assert coherent?(heading_depths(with_profile))
  end

  test "assistant: canonical sections are present and in order" do
    prompt = SystemPrompt.generate_assistant([])

    # Sequence of the top-level sections we rely on elsewhere.
    sections_in_order = [
      "## Turn shape",
      "## Do, don't teach",
      "## Tasks",
      "## Context blocks you will see",
      "## Attachments",
      "## Credentials",
      "## Language",
      "## Voice"
    ]

    indices =
      Enum.map(sections_in_order, fn s ->
        idx = :binary.match(prompt, s)
        refute idx == :nomatch, "missing section: #{s}"
        elem(idx, 0)
      end)

    assert indices == Enum.sort(indices),
           "section order drifted: #{inspect(sections_in_order)} map to #{inspect(indices)}"
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
