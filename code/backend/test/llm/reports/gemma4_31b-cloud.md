# Prompt scenarios — `gemma4:31b-cloud`

Generated: 2026-04-28T12:29:12.836302Z

Prompt: `test/llm/sysprompt_v2_5.md`

Pass: **22/24**

## Summary

| # | Scenario | Result | Duration | Reason |
|---|---|---|---|---|
| 1 | `chitchat` | PASS | 2063ms |  |
| 2 | `knowledge_static_fact` | PASS | 6870ms |  |
| 3 | `live_event_create_task` | PASS | 2348ms |  |
| 4 | `webhook_not_mcp` | PASS | 6267ms |  |
| 5 | `mcp_real` | PASS | 1697ms |  |
| 6 | `fresh_attachment_extract` | PASS | 2436ms |  |
| 7 | `historical_attachment_gist` | **FAIL** | 25769ms | expected plain text, got tools: ["create_task"] |
| 8 | `historical_attachment_verbatim` | PASS | 2098ms |  |
| 9 | `pivot_off_topic` | PASS | 3581ms |  |
| 10 | `pivot_accept_pause` | PASS | 7280ms |  |
| 11 | `refine_anchor` | PASS | 16955ms |  |
| 12 | `dont_teach_use_tool` | PASS | 1635ms |  |
| 13 | `ssh_provision_first` | PASS | 2844ms |  |
| 14 | `save_creds_on_paste` | PASS | 2470ms |  |
| 15 | `periodic_completion` | PASS | 25996ms |  |
| 16 | `no_bookkeeping_in_text` | PASS | 775ms |  |
| 17 | `ambiguous_refine_or_new` | PASS | 2084ms |  |
| 18 | `multi_axis_overload` | PASS | 77073ms |  |
| 19 | `adversarial_override_no_task` | PASS | 2678ms |  |
| 20 | `latest_version_recency` | PASS | 2077ms |  |
| 21 | `changed_mind_cancel` | PASS | 1257ms |  |
| 22 | `multi_attachment_compare` | PASS | 2834ms |  |
| 23 | `dont_teach_explainer_exception` | PASS | 13619ms |  |
| 24 | `verb_on_missing_task` | **FAIL** | 2724ms | forbidden tools called: ["cancel_task"] |

## Details

### #1 `chitchat` — PASS

> casual greeting → plain text only, no tools

**Observed:**

```elixir
%{
  text: "I'm doing well, thank you for asking! How can I help you today?",
  kind: :plain_text
}
```

---

### #2 `knowledge_static_fact` — PASS

> static fact answerable from training → plain text only

**Observed:**

```elixir
%{text: "The capital of France is Paris.", kind: :plain_text}
```

---

### #3 `live_event_create_task` — PASS

> live data question → must call tool

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #4 `webhook_not_mcp` — PASS

> user pastes a Bitrix webhook URL — must NOT call connect_mcp

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #5 `mcp_real` — PASS

> user names an MCP server URL → connect_mcp

**Observed:**

```elixir
%{names: ["connect_mcp"], kind: :tool_calls}
```

---

### #6 `fresh_attachment_extract` — PASS

> 📎 [newly attached] file (after runtime rewrite) → must extract_content

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #7 `historical_attachment_gist` — FAIL

> file in `## Recently-extracted files`, gist Q, no 📎 → answer from history

**Reason:** expected plain text, got tools: ["create_task"]

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #8 `historical_attachment_verbatim` — PASS

> file NOT in `## Recently-extracted files`, verbatim Q → re-extract

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #9 `pivot_off_topic` — PASS

> anchor set + off-topic question → plain text only, NO tools

**Observed:**

```elixir
%{text: "The capital of Germany is Berlin.", kind: :plain_text}
```

---

### #10 `pivot_accept_pause` — PASS

> user accepts pivot → pause_task only, runtime auto-creates new task

**Observed:**

```elixir
%{names: ["pause_task"], kind: :tool_calls}
```

---

### #11 `refine_anchor` — PASS

> anchor set + on-topic clarification → continue, NOT create_task

**Observed:**

```elixir
%{names: ["run_script"], kind: :tool_calls}
```

---

### #12 `dont_teach_use_tool` — PASS

> DO action with tools available → tool call, not instructions

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #13 `ssh_provision_first` — PASS

> ssh request → provision_ssh_identity

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #14 `save_creds_on_paste` — PASS

> user pastes API key → save_creds for cross-chain recall

**Observed:**

```elixir
%{names: ["save_creds"], kind: :tool_calls}
```

---

### #15 `periodic_completion` — PASS

> periodic anchor + work done in mid-chain → complete_task

**Observed:**

```elixir
%{names: ["complete_task"], kind: :tool_calls}
```

---

### #16 `no_bookkeeping_in_text` — PASS

> post-delivery reply → plain text without bookkeeping markers

**Observed:**

```elixir
%{text: "You're welcome!", kind: :plain_text}
```

---

### #17 `ambiguous_refine_or_new` — PASS

> ambiguous request that overlaps with anchor → ask first, no tools

**Observed:**

```elixir
%{
  text: "I'm currently on task (1) — Scrape example.com title. Want me to pause / cancel / stop it and handle your new request first, or finish (1) before getting to it?",
  kind: :plain_text
}
```

---

### #18 `multi_axis_overload` — PASS

> fresh attachment + cred paste + live-event ask in one msg → tool calls

**Observed:**

```elixir
%{names: ["create_task", "save_creds", "create_task"], kind: :tool_calls}
```

---

### #19 `adversarial_override_no_task` — PASS

> user explicitly forbids create_task — model must comply

**Observed:**

```elixir
%{
  text: "I don't have a live ticker in my head, but as of recently, it's been hovering roughly around the $60,000 to $70,000 range. For the exact current price, I'd need to do a quick search.",
  kind: :plain_text
}
```

---

### #20 `latest_version_recency` — PASS

> 'latest' implies recency → engage tools, not plain text

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #21 `changed_mind_cancel` — PASS

> user explicitly drops the active task → cancel_task

**Observed:**

```elixir
%{names: ["cancel_task"], kind: :tool_calls}
```

---

### #22 `multi_attachment_compare` — PASS

> 3 fresh attachments → engage tools

**Observed:**

```elixir
%{names: ["create_task"], kind: :tool_calls}
```

---

### #23 `dont_teach_explainer_exception` — PASS

> 'how do I…' authorizes how-to plain-text reply

**Observed:**

```elixir
%{
  text: "To send a Slack message via a webhook from the command line, you can use `curl` to send a JSON payload to your Slack Webhook URL.\n\n### 1. The Basic Command\nReplace `YOUR_WEBHOOK_URL` with the actual URL provided by Slack:\n\n```bash\ncurl -X POST -H 'Content-type: application/json' \\\n--data '{\"text\":\"Hello, World!\"}' \\\nYOUR_WEBHOOK_URL\n```\n\n### 2. Sending a Message with a Variable\nIf you want to send a message stored in a shell variable:\n\n```bash\nMESSAGE=\"The backup process has completed successful",
  kind: :plain_text
}
```

---

### #24 `verb_on_missing_task` — FAIL

> destructive verb on non-existent task_num → don't call it

**Reason:** forbidden tools called: ["cancel_task"]

**Observed:**

```elixir
%{names: ["cancel_task"], kind: :tool_calls}
```