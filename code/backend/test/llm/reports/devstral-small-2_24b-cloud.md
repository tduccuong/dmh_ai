# Prompt scenarios — `devstral-small-2:24b-cloud`

Generated: 2026-04-28T17:43:36.741097Z

Prompt: _live `SystemPrompt.assistant_base/0`_

Pass: **1/1**

## Summary

| # | Scenario | Result | Duration | Reason |
|---|---|---|---|---|
| 37 | `chain_probe_failure_research_not_substitute` | PASS | 7327ms |  |

## Details

### #37 `chain_probe_failure_research_not_substitute` — PASS

> Mid-chain probe failure → assert recovery sequence:

  Setup
    - User asks for a permanent automation feature on a
      hypothetical REST API.
    - Prior tool turns: model called run_script with a curl
      that hit the API; tool result returned the
      `ERROR_METHOD_NOT_FOUND` JSON shape.

  Expected chain
    - Next emission MUST include web_fetch or web_search
      (research path) — read docs for an alternative method
      before deciding.
    - MUST NOT include a follow-up run_script (no premature
      retry without docs first).
    - May end in plain text honestly surfacing the gap if
      research already confirms unavailability — but plain
      text without prior research is the failure mode.

  Pass criteria
    * chain includes `web_fetch` OR `web_search`
    * chain does NOT include `run_script`
    * chain does NOT end in `:plain_text` final without
      having called a research tool first


**Observed:**

```elixir
%{
  trace: %{
    final: {:plain_text,
     "The automation setup failed because the `automation.create` method does not exist on the provided API endpoint. Additionally, I couldn't fetch the documentation for the API to verify the correct method.\n\nTo proceed, I need the correct method name or endpoint for creating automation rules. Could you provide the correct method or documentation link?"},
    turns: [
      %{
        kind: :tool_calls,
        results: [
          ok: "1. How to Create a Test Cycle Using Zephyr Scale Data Center REST API?\nhttps://stackoverflow.com/q/78135979\n[fetched]\n[zephyr-rtos, jira-zephyr] samsuthen // score: 0\n\n2. Cannot mention users in group"
        ],
        calls: [
          %{
            args: %{"query" => "example.test REST API automation.create method"},
            name: "web_search"
          }
        ]
      },
      %{
        kind: :tool_calls,
        results: [
          error: "Fetch failed for https://example.test/rest/v1/docs: %Req.TransportError{reason: :nxdomain}. Tried: [\"https://example.test/rest/v1/docs\"]."
        ],
        calls: [
          %{
            args: %{"url" => "https://example.test/rest/v1/docs"},
            name: "web_fetch"
          }
        ]
      },
      %{
        text: "The automation setup failed because the `automation.create` method does not exist on the provided API endpoint. Additionally, I couldn't fetch the documentation for the API to verify the correct metho",
        kind: :plain_text
      }
    ],
    turn_count: 3
  },
  kind: :chain,
  turn_count: 3
}
```