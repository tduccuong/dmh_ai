# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Session do
  @moduledoc """
  The six-beat lesson runtime: recall → read → check → speak → use →
  takeaway.

  The order is deliberate and one part of it is counter-intuitive:
  **reading aloud comes after comprehension, not before.** Reading a
  passage aloud builds decoding, fluency, prosody and verbatim memory for
  its wording — it does not build understanding. So the learner
  understands the text first (`read` + `check`), then says it (`speak`).

  `read` and `speak` render the SAME bilingual rows twice. On the first
  pass the translation is comprehension support; on the second the row is
  a read-aloud target. This is the atom the whole product is built from,
  and it is the same row shape the `/duolang` panel already renders.

  Beat state lives in `sessions.context` under `"duolang"`. Lesson
  messages are filtered from LLM context — the runtime rebuilds state
  from the store rather than replaying panels into a prompt.

  Every beat appends one assistant message with `kind="lesson"` and a
  `lesson` payload discriminated by `beat`.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM, SessionContext, UserAgentMessages}
  alias DmhAi.Duolang.{Check, Coverage, Course, Errors, Generator, Items, KnownWords, Tutor, Workspace}
  alias DmhAi.I18n
  alias DmhAi.Commands.Pipelines.Sentences

  @beats ~w(recall read check speak use takeaway)

  @doc """
  Begin a lesson in the learner's workspace, clearing whatever the last
  one left behind. Emits the first beat — `recall` when items are due,
  otherwise straight to `read`.
  """
  @spec start(String.t()) :: {:ok, String.t()} | {:error, term()}
  def start(user_id) do
    case Course.active(user_id) do
      nil ->
        {:error, :no_course}

      course ->
        session_id = Workspace.reset(user_id, course.id)
        draw = Items.session_draw(user_id, course.target_lang)
        state = %{"reintroduce" => draw.reintroduce}

        if draw.items == [] do
          run_read(user_id, session_id, course, state)
        else
          prompts =
            Enum.map(draw.items, fn i ->
              %{"item_id" => i.id, "prompt" => i.translation, "expected" => i.text}
            end)

          brief(
            user_id,
            session_id,
            course,
            Map.merge(state, %{"recall" => prompts, "cursor" => 0, "answers" => []}),
            "recall"
          )
        end
    end
  end

  @doc """
  Advance the lesson with the learner's reply. Each beat consumes the
  reply its own way, then emits the next.
  """
  @spec advance(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def advance(user_id, session_id, input) do
    with course when not is_nil(course) <- Course.get(user_id, session_id),
         %{"beat" => beat} = state <- state(session_id) do
      dispatch(beat, user_id, session_id, course, state, input)
    else
      _ -> {:error, :no_lesson_in_progress}
    end
  end

  @doc "The beats in order. Exposed so the FE and tests share one source."
  @spec beats() :: [String.t()]
  def beats, do: @beats

  # ── beat dispatch ──────────────────────────────────────────────────────
  #
  # Every user message advances exactly ONE micro-step. A beat holding
  # several items walks them one at a time; presenting a list and hoping
  # the learner packs every answer into a single reply is what made the
  # composer ambiguous ("answer WHAT?").

  defp dispatch("brief", user_id, session_id, course, state, input),
    do: step_brief(user_id, session_id, course, state, input)

  defp dispatch("complete", user_id, session_id, course, state, input),
    do: step_complete(user_id, session_id, course, state, input)

  defp dispatch("recall", user_id, session_id, course, state, input),
    do: step_recall(user_id, session_id, course, state, input)

  defp dispatch("check", user_id, session_id, course, state, input),
    do: step_check(user_id, session_id, course, state, input)

  # The speak drill is driven by the top-pane buttons: Continue (an empty
  # advance) walks to the next line. Anything the learner TYPES is a
  # clarifying question the tutor answers, without advancing the drill.
  defp dispatch("speak", user_id, session_id, course, state, input) do
    if String.trim(to_string(input)) == "" do
      step_speak(user_id, session_id, course, state)
    else
      reply = Tutor.answer(course, :speak, numbered_passage(state), input)
      if reply != "", do: append_tutor(user_id, session_id, reply)
      {:ok, "speak"}
    end
  end

  defp dispatch("use", user_id, session_id, course, state, input),
    do: step_use(user_id, session_id, course, state, input)

  defp dispatch("takeaway", _user_id, _session_id, _learner, _state, _input),
    do: {:error, :lesson_complete}

  defp dispatch(_beat, _user_id, _session_id, _learner, _state, _input),
    do: {:error, :no_lesson_in_progress}

  # ── beat briefings ─────────────────────────────────────────────────────
  #
  # A beat opens with a briefing in the chat: what the step is, what to do,
  # and "type I'm ready to begin, or ask me anything". The material shows in
  # the top pane while the tutor briefs; readiness is a cheap phrase check,
  # anything else is a question the tutor answers.

  defp brief(user_id, session_id, course, state, beat) do
    Course.set_beat(user_id, session_id, beat)
    put_state(session_id, Map.merge(state, %{"beat" => "brief", "brief_for" => beat}))

    emit(
      user_id,
      session_id,
      "brief",
      %{
        "brief_for" => beat,
        "title" => state["title"],
        "rows" => brief_rows(beat, state),
        "answer_language" => course.source_lang,
        "say" => Tutor.briefing(course, beat, state["title"] || course.name)
      },
      course.source_lang
    )
  end

  # Only the reading-based beats carry the passage into their briefing.
  defp brief_rows(beat, state) when beat in ["read", "speak", "use"], do: state["rows"] || []
  defp brief_rows(_beat, _state), do: []

  defp step_brief(user_id, session_id, course, state, input) do
    beat = state["brief_for"]

    if ready?(input) do
      append_tutor(user_id, session_id, I18n.t("brief_go", course.source_lang))
      start_activity(user_id, session_id, course, Map.drop(state, ["brief_for"]), beat)
    else
      reply = Tutor.answer(course, :brief, numbered_passage(state), input)
      if reply != "", do: append_tutor(user_id, session_id, reply)
      {:ok, "brief"}
    end
  end

  # Start the beat's real activity once the learner says they are ready.
  defp start_activity(user_id, session_id, course, state, "recall"),
    do: emit_recall(user_id, session_id, course, state)

  # `read` has no activity of its own — reading the passage IS the activity —
  # so "ready" goes straight to the check questions. Its briefing already told
  # the learner the questions are coming; a separate check briefing would just
  # repeat the read one word-for-word in its opening.
  defp start_activity(user_id, session_id, course, state, "read"),
    do: run_check(user_id, session_id, course, state)

  defp start_activity(user_id, session_id, course, state, "speak"),
    do: run_speak(user_id, session_id, course, state)

  defp start_activity(user_id, session_id, course, state, "use"),
    do: run_use(user_id, session_id, course, state)

  # ── the completion gate ────────────────────────────────────────────────
  #
  # A phase closes with a model-generated congratulations + "ready to move on?"
  # (source language). It emits a `complete` panel — a chat message that keeps
  # the finished material on the stage and keeps the composer open — and holds
  # for consent. Consent opens the next phase; a question is answered and the
  # gate holds. The panel is what stops a transition from dumping the next
  # briefing abruptly under the last answer.

  defp complete(user_id, session_id, course, state, done_beat, next_beat) do
    put_state(session_id, Map.merge(state, %{"beat" => "complete", "next_beat" => next_beat}))

    emit(
      user_id,
      session_id,
      "complete",
      %{
        "done_for" => done_beat,
        "next_for" => next_beat,
        "title" => state["title"],
        "rows" => state["rows"] || [],
        "answer_language" => course.source_lang,
        "say" => Tutor.completion(course, done_beat, next_beat)
      },
      course.source_lang
    )
  end

  defp step_complete(user_id, session_id, course, state, input) do
    if ready?(input) do
      start_next(user_id, session_id, course, Map.drop(state, ["next_beat"]), state["next_beat"])
    else
      reply = Tutor.answer(course, :complete, numbered_passage(state), input)
      if reply != "", do: append_tutor(user_id, session_id, reply)
      {:ok, "complete"}
    end
  end

  # Open the next phase once the learner consents. `read` regenerates the
  # passage and briefs the Understand phase; the rest brief their own beat;
  # `takeaway` shows the recap.
  defp start_next(user_id, session_id, course, state, "read"),
    do: run_read(user_id, session_id, course, state)

  # Speak has no briefing gate — its drill is driven by the top-pane buttons,
  # so an "I'm ready" step would contradict them. It opens straight into the
  # drill (line 1) with the briefing in the chat. The drill panel is emitted
  # first so it anchors the Speak tab and the briefing lands under it.
  defp start_next(user_id, session_id, course, state, "speak") do
    result = run_speak(user_id, session_id, course, state)
    append_tutor(user_id, session_id, Tutor.briefing(course, "speak", state["title"] || course.name))
    result
  end

  defp start_next(user_id, session_id, course, state, beat),
    do: brief(user_id, session_id, course, state, beat)

  # A cheap readiness check — no model call on the common path. Anything not
  # matching is treated as a clarifying question.
  @consent_words ~w(
    ok okay yes yeah yep yup sure ready go start begin next continue proceed onward
    ja los weiter si sí vale oui vâng dạ ừ rồi có được tiếp
  )
  defp ready?(input) do
    norm = input |> to_string() |> String.downcase() |> String.trim()

    norm in @consent_words or
      String.contains?(norm, [
        "ready", "let's go", "lets go", "let's start", "lets start", "i'm ready", "i am ready",
        "go ahead", "begin", "start now", "move on", "move forward", "go on", "keep going",
        "next phase", "next step", "let's continue", "lets continue",
        "sẵn sàng", "bắt đầu", "tiếp tục", "tiếp theo", "đồng ý", "được rồi",
        "bereit", "anfangen", "los geht", "mach weiter", "weitermachen",
        "listo", "empez", "vamos", "adelante", "continuar", "siguiente",
        "prêt", "prete", "commenc", "allons", "continuer", "en avant"
      ])
  end

  # Answer a clarifying question asked during the briefing, in the learner's
  # language, using the passage when there is one.
  # ── 1. recall — one item per turn ──────────────────────────────────────

  defp emit_recall(user_id, session_id, course, state) do
    prompts = state["recall"] || []
    cursor = state["cursor"] || 0
    item = Enum.at(prompts, cursor) || %{}
    back? = state["reintroduce"] == true
    put_state(session_id, Map.put(state, "beat", "recall"))

    say =
      I18n.t(if(back?, do: "say_recall_back", else: "say_recall"), course.source_lang, %{
        lang: language_name(course.target_lang),
        prompt: item["prompt"]
      })

    emit(
      user_id,
      session_id,
      "recall",
      %{
        "prompt" => item["prompt"],
        # After an absence the learner is shown the answer rather than
        # tested on it, so the pair is revealed and nothing is marked.
        "answer" => if(back?, do: item["expected"]),
        "index" => cursor + 1,
        "total" => length(prompts),
        "reintroduce" => back?,
        "say" => say
      },
      course.source_lang
    )
  end

  defp step_recall(user_id, session_id, course, state, input) do
    prompts = state["recall"] || []
    answers = (state["answers"] || []) ++ [input]
    cursor = (state["cursor"] || 0) + 1

    if cursor < length(prompts) do
      emit_recall(user_id, session_id, course, Map.merge(state, %{"cursor" => cursor, "answers" => answers}))
    else
      score_recall(user_id, course.target_lang, prompts, answers, state["reintroduce"] == true)
      complete(user_id, session_id, course, Map.drop(state, ["cursor", "answers", "recall"]), "recall", "read")
    end
  end

  defp score_recall(user_id, lang, prompts, _answers, true) do
    Enum.each(prompts, &Items.record_result(user_id, lang, &1["item_id"], :skipped, "recall"))
  end

  defp score_recall(user_id, lang, prompts, answers, false) do
    responses =
      prompts
      |> Enum.zip(answers)
      |> Enum.map(fn {p, given} ->
        %{item: p["expected"], expected: p["expected"], given: given}
      end)

    verdicts =
      case Check.score_probes(responses, meta: %{user_id: user_id}) do
        {:ok, v} when length(v) == length(prompts) -> v
        _ -> Enum.map(responses, &%{item: &1.item, correct: false, expected: &1.expected})
      end

    prompts
    |> Enum.zip(verdicts)
    |> Enum.each(fn {p, v} ->
      result = if v.correct, do: :correct, else: :incorrect
      Items.record_result(user_id, lang, p["item_id"], result, "recall")
      if v.correct, do: Errors.retire_for_item(user_id, p["item_id"])
    end)
  end

  # ── 2. read ────────────────────────────────────────────────────────────

  defp run_read(user_id, session_id, course, state) do
    plan = Course.level_plan(course, course.current_level)

    ctx = %{
      user_id: user_id,
      target_lang: course.target_lang,
      source_lang: course.source_lang,
      topic: course.topic,
      level: course.current_level,
      theme: plan["theme"],
      can_do: plan["can_do"]
    }

    case Generator.generate(ctx, meta: %{session_id: session_id, user_id: user_id}) do
      {:ok, result} ->
        rows = rows_for(result, course)

        merged =
          Map.merge(state, %{
            "text" => result.text,
            "topic" => result.topic,
            "title" => result.title,
            "rows" => rows,
            "new_words" => content_words(result.report.missing_words),
            "stage" => to_string(result.stage),
            "items" => Enum.map(result.items, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
          })

        brief(user_id, session_id, course, merged, "read")

      {:error, reason} ->
        Logger.warning("[Duolang.Session] generate failed: #{inspect(reason)}")
        {:error, :generation_failed}
    end
  end

  # One row per sentence. The translation is produced alongside so the row
  # can serve as comprehension support on this pass and a read-aloud
  # target on the next.
  defp rows_for(result, course) do
    target = Course.target_language(course)
    source = Course.source_language(course)
    translations = translate_rows(result.sentences, course)

    result.sentences
    |> Enum.zip(translations)
    |> Enum.map(fn {original, translation} ->
      %{
        "original" => original,
        "translation" => translation,
        "bcp47" => bcp47(target),
        "source_bcp47" => bcp47(source)
      }
    end)
  end

  defp translate_rows(sentences, course) do
    source = language_name(course.source_lang)
    body = Jason.encode!(%{"target" => source, "sentences" => sentences})

    messages = [
      %{
        role: "system",
        content: """
        You are a translation engine. You receive a JSON object with a target
        language and an ordered array of sentences. Translate every sentence into
        the target language.

        Output STRICT JSON with one key:

          {"translations": ["…", "…"]}

        One translation per input sentence, in the same order, same count.
        Preserve meaning and register. The first character must be `{`.
        """
      },
      %{role: "user", content: body}
    ]

    with {:ok, raw} when is_binary(raw) <-
           LLM.call(AgentSettings.swift_model(), messages,
             options: %{temperature: 0},
             trace: trace(%{user_id: course.user_id}, "translate_rows")
           ),
         {:ok, %{"translations" => list}} when is_list(list) <-
           DmhAi.Commands.Pipelines.Sentences.decode_llm_json(raw),
         true <- length(list) == length(sentences) do
      Enum.map(list, &to_string/1)
    else
      _ -> Enum.map(sentences, fn _ -> "" end)
    end
  end

  # ── 3. check — an AI-driven comprehension conversation ─────────────────
  #
  # Not a fixed quiz. The tutor asks about the passage, reads the answer, and
  # decides whether the learner has understood or needs another question —
  # one model call per turn returns the reply, an understood verdict, and the
  # next question. The loop is bounded so it always terminates.

  defp run_check(user_id, session_id, course, state) do
    question = first_check_question(course, state)

    put_state(
      session_id,
      Map.merge(state, %{"beat" => "check", "check_q" => question, "check_count" => 1, "check_history" => []})
    )

    # The passage stays on the stage while the tutor asks, so the learner has
    # what they are being asked about in front of them.
    emit(
      user_id,
      session_id,
      "check",
      %{
        "title" => state["title"],
        "rows" => state["rows"] || [],
        "answer_language" => course.source_lang,
        "say" => question
      },
      course.source_lang
    )
  end

  defp step_check(user_id, session_id, course, state, input) do
    question = state["check_q"] || ""
    count = state["check_count"] || 1
    history = (state["check_history"] || []) ++ [%{"q" => question, "a" => input}]
    max = AgentSettings.duolang_max_check_questions()

    turn = check_turn(course, state, history)
    reply = String.trim(turn["reply"] || "")
    understood = turn["understood"] == true
    next_q = String.trim(turn["next_question"] || "")

    if reply != "", do: append_tutor(user_id, session_id, reply)

    cond do
      understood ->
        # They have shown they follow it — the passage's words count as known.
        KnownWords.record_met(user_id, course.target_lang, state["text"] || "")
        complete(user_id, session_id, course, Map.drop(state, ["check_q", "check_count", "check_history"]), "check", "speak")

      count >= max or next_q == "" ->
        # Asked enough, or nothing more to ask — move on without marking known.
        complete(user_id, session_id, course, Map.drop(state, ["check_q", "check_count", "check_history"]), "check", "speak")

      true ->
        append_tutor(user_id, session_id, next_q)

        put_state(
          session_id,
          Map.merge(state, %{"beat" => "check", "check_q" => next_q, "check_count" => count + 1, "check_history" => history})
        )

        {:ok, "check"}
    end
  end

  # The opening comprehension question, in the learner's own language.
  defp first_check_question(course, state) do
    target = language_name(course.target_lang)
    source = language_name(course.source_lang)

    system = """
    You are a warm tutor checking that someone learning #{target} understood a
    short numbered passage. Ask ONE clear comprehension question in #{source}
    about what the passage says. Plain text, one question, no preamble.
    """

    case LLM.call(
           AgentSettings.confidant_model(),
           [%{role: "system", content: system}, %{role: "user", content: numbered_passage(state)}],
           options: %{temperature: 0.5},
           trace: trace(%{user_id: course.user_id}, "check_first_q")
         ) do
      {:ok, text} when is_binary(text) and text != "" -> String.trim(text)
      _ -> I18n.t("say_check_fallback", course.source_lang)
    end
  end

  # One turn of the check conversation: react to the latest answer, judge
  # cumulative understanding, and ask the next question when needed.
  defp check_turn(course, state, history) do
    target = language_name(course.target_lang)
    source = language_name(course.source_lang)

    system = """
    You are a warm, patient tutor helping someone learn #{target}, checking they
    understood a short numbered passage. You speak #{source}.

    You are given the passage and the whole conversation so far. React to their
    LATEST answer:

      - reply: one or two sentences in #{source}. If they got it, affirm and add
        one small useful detail. If they are unsure, said they do not know, or
        got it wrong, gently give the answer using the passage and point them to
        the line(s); never scold.
      - understood: true only once they have shown, across the conversation, that
        they follow the passage well enough to move on; otherwise false.
      - next_question: when understood is false, ONE more question in #{source}
        about a part they have not yet shown they grasp; when true, empty.

    If they refer to a line by its number, it means that exact numbered line.

    Output STRICT JSON, first character `{`, no markdown fences:
      {"reply": "...", "understood": true|false, "next_question": "..."}
    """

    user = "Passage (numbered lines):\n#{numbered_passage(state)}\n\nConversation so far:\n#{format_history(history)}"

    with {:ok, raw} when is_binary(raw) <-
           LLM.call(AgentSettings.confidant_model(),
             [%{role: "system", content: system}, %{role: "user", content: user}],
             options: %{temperature: 0.5},
             trace: trace(%{user_id: course.user_id}, "check_turn")
           ),
         {:ok, %{} = d} <- Sentences.decode_llm_json(raw) do
      d
    else
      # On any failure, move on rather than trap the learner in the loop.
      _ -> %{"reply" => "", "understood" => true, "next_question" => ""}
    end
  end

  defp format_history(history) do
    Enum.map_join(history, "\n\n", fn %{"q" => q, "a" => a} -> "Tutor: #{q}\nLearner: #{a}" end)
  end

  # The passage as numbered lines, matching what the learner sees, so the
  # model can resolve a reference like "line 3".
  defp numbered_passage(state) do
    rows = state["rows"] || []

    if rows == [] do
      state["text"] || ""
    else
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} -> "#{i}. #{r["original"]}" end)
    end
  end

  # A plain tutor turn in the conversation (bottom pane), no panel.
  defp append_tutor(user_id, session_id, text) do
    {:ok, _ts} =
      UserAgentMessages.append(session_id, user_id, %{role: "assistant", content: text})

    :ok
  end

  # ── 4. speak — one line per turn ───────────────────────────────────────

  # Recognition happens in the browser and only ever answers "did the
  # intended words come through" — no score, no per-word verdict on
  # connected speech.
  defp run_speak(user_id, session_id, course, state),
    do: emit_speak(user_id, session_id, course, Map.merge(state, %{"beat" => "speak", "cursor" => 0}))

  defp emit_speak(user_id, session_id, course, state) do
    rows = state["rows"] || []
    cursor = state["cursor"] || 0
    put_state(session_id, Map.put(state, "beat", "speak"))

    emit(
      user_id,
      session_id,
      "speak",
      %{
        "row" => Enum.at(rows, cursor),
        "index" => cursor + 1,
        "total" => length(rows),
        "title" => state["title"],
        "rows" => rows,
        "model_rate" => AgentSettings.duolang_model_speech_rate(),
        "watchdog_ms" => AgentSettings.duolang_asr_watchdog_ms(),
        # No per-line chat line — the drill lives in the top pane (speaker +
        # mic + Continue). An empty `say` keeps it out of the transcript; the
        # briefing already told the learner to use those buttons.
        "say" => ""
      },
      course.source_lang
    )
  end

  defp step_speak(user_id, session_id, course, state) do
    rows = state["rows"] || []
    cursor = (state["cursor"] || 0) + 1

    if cursor < length(rows) do
      emit_speak(user_id, session_id, course, Map.put(state, "cursor", cursor))
    else
      complete(user_id, session_id, course, Map.drop(state, ["cursor"]), "speak", "use")
    end
  end

  # ── 5. use ─────────────────────────────────────────────────────────────

  defp run_use(user_id, session_id, course, state) do
    items = state["items"] || []
    opening = opener(course, state)

    put_state(
      session_id,
      Map.merge(state, %{"beat" => "use", "use_count" => 1, "use_history" => [%{"role" => "tutor", "text" => opening}]})
    )

    emit(user_id, session_id, "use", %{
      "title" => state["title"],
      "rows" => state["rows"] || [],
      "target_items" => Enum.map(items, &Map.get(&1, "text")),
      "bcp47" => bcp47(Course.target_language(course)),
      # The role-play plays out in the chat; the panel only holds the dialogue
      # for reference, so it carries no chat line of its own.
      "say" => ""
    }, course.source_lang)

    append_tutor(user_id, session_id, opening)
    {:ok, "use"}
  end

  defp opener(course, state) do
    target = language_name(course.target_lang)

    prompt = """
    You are a tutor opening a role-play so someone can practise using #{target}, based on this dialogue:

    #{numbered_passage(state)}

    Play your FIRST line to open the role-play — in character as one side of this scenario, in #{target}
    only, one or two sentences — inviting them to respond as the other side. Do not explain or translate;
    just speak your opening line.
    """

    case LLM.call(AgentSettings.confidant_model(), [%{role: "user", content: prompt}],
           options: %{temperature: 0.7},
           trace: trace(%{user_id: course.user_id}, "use_opener")
         ) do
      {:ok, text} when is_binary(text) -> String.trim(text)
      _ -> ""
    end
  end

  # One turn of the model-directed role-play. The model plays its role, judges
  # whether the learner can now carry the scenario (`done`), and notes what they
  # got wrong. Corrections go to the ledger for the closing takeaway — none
  # interrupt the exchange. The beat holds until the model says `done` OR the
  # (deliberately high) turn cap is hit, so the learner has to put in real work.
  defp step_use(user_id, session_id, course, state, input) do
    count = state["use_count"] || 1
    max = AgentSettings.duolang_max_use_turns()
    history = (state["use_history"] || []) ++ [%{"role" => "learner", "text" => input}]

    turn = use_turn(course, state, history, count, max)
    reply = String.trim(turn["reply"] || "")
    done = turn["done"] == true or count >= max

    Enum.each(decode_corrections(turn["corrections"]), fn c ->
      Errors.record(user_id, course.target_lang, %{kind: c.kind, detail: c.detail, fix: c.fix})
    end)

    if reply != "", do: append_tutor(user_id, session_id, reply)

    if done do
      run_takeaway(user_id, session_id, course, Map.drop(state, ["use_count", "use_history"]))
    else
      put_state(
        session_id,
        Map.merge(state, %{
          "beat" => "use",
          "use_count" => count + 1,
          "use_history" => history ++ [%{"role" => "tutor", "text" => reply}]
        })
      )

      {:ok, "use"}
    end
  end

  defp use_turn(course, state, history, count, max) do
    target = language_name(course.target_lang)

    system = """
    You are a language tutor DIRECTING a role-play so someone can practise USING #{target}, grounded in
    today's dialogue.

    Today's dialogue (numbered lines):
    #{numbered_passage(state)}

    Run it as a role-play entirely in #{target}: you play one side of this scenario, they play the
    other. Stay in character, keep it natural, and steer them into producing the words and structures
    from the dialogue — vary the situation so they must use the language, not just echo a line back.

    They have taken #{count} of up to #{max} turns. Keep the exchange going until they have genuinely
    shown they can hold this scenario in #{target}; do not end early.

    Output STRICT JSON, first character `{`, no fences:
      {"reply": "<your next line, in character, in #{target}, one or two sentences>",
       "done": <true ONLY once they can clearly carry this scenario in #{target}; otherwise false>,
       "corrections": [{"kind": "grammar|vocabulary|word_order|form", "detail": "what was wrong", "fix": "the corrected form"}]}
    """

    user = "Conversation so far:\n" <> Enum.map_join(history, "\n", fn t -> "#{t["role"]}: #{t["text"]}" end)

    with {:ok, raw} when is_binary(raw) <-
           LLM.call(AgentSettings.confidant_model(),
             [%{role: "system", content: system}, %{role: "user", content: user}],
             options: %{temperature: 0.7},
             trace: trace(%{user_id: course.user_id}, "use_turn")),
         {:ok, %{} = turn} <- DmhAi.Commands.Pipelines.Sentences.decode_llm_json(raw) do
      turn
    else
      _ -> %{"reply" => "", "done" => false, "corrections" => []}
    end
  end

  # ── 6. takeaway ────────────────────────────────────────────────────────

  # One thing, chosen as the most persistent open error. When there is
  # nothing open the session says so rather than inventing a correction.
  defp run_takeaway(user_id, session_id, course, state) do
    Enum.each(state["items"] || [], fn item ->
      Items.upsert(user_id, course.target_lang, %{
        kind: Map.get(item, "kind", "word"),
        text: Map.get(item, "text"),
        translation: Map.get(item, "translation"),
        context: state["text"]
      })
    end)

    takeaway = Errors.takeaway(user_id, course.target_lang)
    # Completing the six beats advances the course to the next CEFR level;
    # the next lesson's passages are pitched there.
    Course.advance(user_id, session_id)
    put_state(session_id, Map.merge(state, %{"beat" => "takeaway"}))

    emit(user_id, session_id, "takeaway", %{
      "takeaway" =>
        takeaway && %{"detail" => takeaway.detail, "fix" => takeaway.fix, "kind" => takeaway.kind},
      "items_added" => length(state["items"] || []),
      "coverage" => coverage_payload(user_id, course)
    }, course.source_lang)
  end

  defp coverage_payload(user_id, course) do
    case Coverage.for_user(user_id, course.target_lang) do
      {:ok, report} -> %{"percent" => report.percent}
      {:error, :no_reference} -> nil
    end
  end

  # New-word chips exist to show what the passage teaches. Function words —
  # articles, pronouns, particles — are noise there, and a chip list led by
  # "i / to / a / is" reads as broken rather than instructive.
  @function_word_max_len 3
  defp content_words(words) do
    Enum.reject(words, &(String.length(&1) <= @function_word_max_len))
  end

  # ── state + emit ───────────────────────────────────────────────────────

  @doc "The current lesson state, or `nil` when no lesson is in progress."
  @spec state(String.t()) :: map() | nil
  def state(session_id) do
    case SessionContext.get(session_id) do
      %{"duolang" => %{} = duolang} -> duolang
      _ -> nil
    end
  end

  defp put_state(session_id, state), do: SessionContext.merge(session_id, %{"duolang" => state})

  defp emit(user_id, session_id, beat, payload, lang) do
    {:ok, _ts} =
      UserAgentMessages.append(session_id, user_id, %{
        role: "assistant",
        content: payload["say"] || fallback_text(beat, payload, lang),
        kind: "lesson",
        lesson: Map.put(payload, "beat", beat)
      })

    # The transcript id is the course id, so the course's current-beat can be
    # kept in step for the topbar status without a separate lookup.
    if beat in @beats, do: Course.set_beat(user_id, session_id, beat)
    {:ok, beat}
  end

  # Plain-text stand-in for clients that cannot render the `lesson` field.
  # A client that CAN render it shows the panel instead, never both.
  # Written in the learner's own language, not the language being learned.
  defp fallback_text("recall", p, lang),
    do: I18n.t("lesson_recall", lang, %{n: length(p["items"] || [])})

  defp fallback_text("read", p, lang),
    do: I18n.t("lesson_read", lang, %{topic: p["topic"]})

  defp fallback_text("check", p, lang),
    do: I18n.t("lesson_check", lang, %{n: length(p["prompts"] || [])})

  defp fallback_text("speak", p, lang),
    do: I18n.t("lesson_speak", lang, %{n: length(p["rows"] || [])})

  defp fallback_text("takeaway", _p, lang), do: I18n.t("lesson_takeaway", lang)

  # These three already carry model-written prose in the right language.
  defp fallback_text("check_result", p, _lang), do: p["comment"] || ""
  defp fallback_text("use", p, _lang), do: p["opener"] || ""
  defp fallback_text("use_result", p, _lang), do: p["reply"] || ""
  defp fallback_text(_beat, _p, _lang), do: ""

  # ── helpers ────────────────────────────────────────────────────────────


  defp decode_corrections(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"kind" => k, "detail" => d, "fix" => f} when is_binary(d) and is_binary(f) ->
        %{kind: to_string(k), detail: String.trim(d), fix: String.trim(f)}

      _ ->
        nil
    end)
    |> Enum.reject(&(is_nil(&1) or &1.detail == ""))
  end

  defp decode_corrections(_), do: []

  defp bcp47(%{bcp47: tag}), do: tag
  defp bcp47(_), do: nil

  defp language_name(code) do
    case DmhAi.Commands.Languages.by_code(code) do
      %{english: name} -> name
      _ -> code
    end
  end

  defp trace(meta, phase) do
    %{
      origin: "duolang",
      path: "Duolang.Session.#{phase}",
      role: "Duolang",
      phase: phase,
      session_id: Map.get(meta, :session_id),
      user_id: Map.get(meta, :user_id),
      tier: if(phase in ["use_turn", "use_opener"], do: :master, else: :swift)
    }
  end
end
