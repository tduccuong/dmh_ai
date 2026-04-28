# Prompt scenarios — `devstral-small-2:24b-cloud`

Generated: 2026-04-28T15:59:39.313358Z

Prompt: _live `SystemPrompt.assistant_base/0`_

Pass: **34/35**

## Summary

| # | Scenario | Result | Duration | Reason |
|---|---|---|---|---|
| 1 | `chitchat` | PASS | 1800ms |  |
| 2 | `knowledge_static_fact` | PASS | 1226ms |  |
| 3 | `live_event_create_task` | PASS | 1709ms |  |
| 4 | `webhook_not_mcp` | PASS | 1725ms |  |
| 5 | `mcp_real` | PASS | 1277ms |  |
| 6 | `fresh_attachment_extract` | PASS | 1848ms |  |
| 7 | `historical_attachment_gist` | PASS | 2863ms |  |
| 8 | `historical_attachment_verbatim` | PASS | 879ms |  |
| 9 | `pivot_off_topic` | PASS | 873ms |  |
| 10 | `pivot_accept_pause` | PASS | 1092ms |  |
| 11 | `refine_anchor` | **FAIL** | 1921ms | forbidden tools called: ["create_task"] |
| 12 | `dont_teach_use_tool` | PASS | 1254ms |  |
| 13 | `ssh_provision_first` | PASS | 1033ms |  |
| 14 | `save_creds_on_paste` | PASS | 1560ms |  |
| 15 | `periodic_completion` | PASS | 1207ms |  |
| 16 | `no_bookkeeping_in_text` | PASS | 1411ms |  |
| 17 | `ambiguous_refine_or_new` | PASS | 1564ms |  |
| 18 | `multi_axis_overload` | PASS | 2430ms |  |
| 19 | `adversarial_override_no_task` | PASS | 1622ms |  |
| 20 | `latest_version_recency` | PASS | 934ms |  |
| 21 | `changed_mind_cancel` | PASS | 1079ms |  |
| 22 | `multi_attachment_compare` | PASS | 1840ms |  |
| 23 | `dont_teach_explainer_exception` | PASS | 6414ms |  |
| 24 | `verb_on_missing_task` | PASS | 1235ms |  |
| 26 | `mcp_oauth_needs_auth` | PASS | 1074ms |  |
| 27 | `chain_oauth_callback_resume` | PASS | 2389ms |  |
| 28 | `mcp_api_key_needs_setup` | PASS | 1088ms |  |
| 29 | `request_input_two_fields` | PASS | 1973ms |  |
| 30 | `request_input_single_field_uses_text` | PASS | 1761ms |  |
| 32 | `request_input_multi_field_config` | PASS | 1890ms |  |
| 33 | `request_input_two_inputs_borderline` | PASS | 1484ms |  |
| 34 | `open_ended_uses_prose` | PASS | 2316ms |  |
| 35 | `chain_mcp_connect_oauth_needs_auth` | PASS | 1112ms |  |
| 36 | `chain_request_input_terminates` | PASS | 1484ms |  |
| 31 | `save_creds_payload_shape` | PASS | 1231ms |  |

## Details

### #1 `chitchat` — PASS

> casual greeting → plain text only, no tools

**Observed:**

```elixir
%{text: "Hi! I'm here and ready to help. How about you?", kind: :plain_text}
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
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "language" => "en",
        "task_spec" => "What is the bitcoin price right now in USD?",
        "task_title" => "Check Bitcoin price in USD",
        "task_type" => "one_off"
      },
      name: "create_task"
    }
  ]
}
```

---

### #4 `webhook_not_mcp` — PASS

> user pastes a Bitrix webhook URL — must NOT call connect_mcp

**Observed:**

```elixir
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "language" => "en",
        "task_spec" => "Create a new deal in Bitrix24 via this inbound webhook: https://example.bitrix24.de/rest/1/abc123def456/",
        "task_title" => "Create a new deal in Bitrix24",
        "task_type" => "one_off"
      },
      name: "create_task"
    }
  ]
}
```

---

### #5 `mcp_real` — PASS

> user names an MCP server URL → connect_mcp

**Observed:**

```elixir
%{
  names: ["connect_mcp"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{"auth_method" => "auto", "url" => "https://huggingface.co/mcp"},
      name: "connect_mcp"
    }
  ]
}
```

---

### #6 `fresh_attachment_extract` — PASS

> 📎 [newly attached] file (after runtime rewrite) → must extract_content

**Observed:**

```elixir
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "attachments" => ["workspace/data/quarterly_report.pdf"],
        "language" => "en",
        "task_spec" => "please summarize this report.",
        "task_title" => "Summarize the quarterly report",
        "task_type" => "one_off"
      },
      name: "create_task"
    }
  ]
}
```

---

### #7 `historical_attachment_gist` — PASS

> file in `## Recently-extracted files`, gist Q, no 📎 → answer from history

**Observed:**

```elixir
%{
  text: "The report also covers:\n\n- **Operational Metrics**: Detailed breakdown of revenue growth by region, customer acquisition costs, and churn rates.\n- **Product Development**: Updates on the edge runtime v2, including new features, performance benchmarks, and adoption metrics.\n- **Team Expansion**: Profiles of the eight new hires, their roles, and the impact on team structure.\n- **Financial Health**: Cash flow analysis, burn rate, and runway projections.\n- **Customer Feedback**: Highlights from cust",
  kind: :plain_text
}
```

---

### #8 `historical_attachment_verbatim` — PASS

> file NOT in `## Recently-extracted files`, verbatim Q → re-extract

**Observed:**

```elixir
%{
  names: ["fetch_task"],
  kind: :tool_calls,
  calls: [%{args: %{"task_num" => 1}, name: "fetch_task"}]
}
```

---

### #9 `pivot_off_topic` — PASS

> anchor set + off-topic question → plain text only, NO tools

**Observed:**

```elixir
%{text: "Berlin.", kind: :plain_text}
```

---

### #10 `pivot_accept_pause` — PASS

> user accepts pivot → pause_task only, runtime auto-creates new task

**Observed:**

```elixir
%{
  names: ["pause_task"],
  kind: :tool_calls,
  calls: [%{args: %{"task_num" => 1}, name: "pause_task"}]
}
```

---

### #11 `refine_anchor` — FAIL

> anchor set + on-topic clarification → continue, NOT create_task

**Reason:** forbidden tools called: ["create_task"]

**Observed:**

```elixir
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "attachments" => [],
        "language" => "en",
        "task_spec" => "create a deal in bitrix24 using the inbound webhook URL https://example.bitrix24.de/rest/1/x/ with category=2",
        "task_title" => "Create a Bitrix24 deal via webhook",
        "task_type" => "one_off"
      },
      name: "create_task"
    }
  ]
}
```

---

### #12 `dont_teach_use_tool` — PASS

> DO action with tools available → tool call, not instructions

**Observed:**

```elixir
%{
  names: ["web_fetch"],
  kind: :tool_calls,
  calls: [%{args: %{"url" => "https://example.com"}, name: "web_fetch"}]
}
```

---

### #13 `ssh_provision_first` — PASS

> ssh request → provision_ssh_identity

**Observed:**

```elixir
%{
  names: ["provision_ssh_identity"],
  kind: :tool_calls,
  calls: [
    %{args: %{"host" => "ubuntu@1.2.3.4"}, name: "provision_ssh_identity"}
  ]
}
```

---

### #14 `save_creds_on_paste` — PASS

> user pastes API key → save_creds for cross-chain recall

**Observed:**

```elixir
%{
  names: ["save_creds"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "kind" => "api_key",
        "payload" => %{"value" => "sk-test-1234567890abcdef"},
        "target" => "openai_api"
      },
      name: "save_creds"
    }
  ]
}
```

---

### #15 `periodic_completion` — PASS

> periodic anchor + work done in mid-chain → complete_task

**Observed:**

```elixir
%{
  names: ["complete_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "task_num" => 1,
        "task_result" => "Fetched and summarized today's top 5 tech headlines."
      },
      name: "complete_task"
    }
  ]
}
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
  text: "I'm currently on task (1) — fetching the title of https://example.com. Want me to pause or cancel it and handle your new request first, or finish (1) before getting to it?",
  kind: :plain_text
}
```

---

### #18 `multi_axis_overload` — PASS

> fresh attachment + cred paste + live-event ask in one msg → tool calls

**Observed:**

```elixir
%{
  names: ["create_task", "save_creds"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "attachments" => ["workspace/data/openai_audit.csv"],
        "language" => "en",
        "task_spec" => "Extract content from the newly attached file workspace/data/openai_audit.csv.",
        "task_title" => "Extract content from openai_audit.csv",
        "task_type" => "one_off"
      },
      name: "create_task"
    },
    %{
      args: %{
        "kind" => "api_key",
        "payload" => %{"value" => "sk-test-mxBpSuf78ABCDEFGH"},
        "target" => "openai_api"
      },
      name: "save_creds"
    }
  ]
}
```

---

### #19 `adversarial_override_no_task` — PASS

> user explicitly forbids create_task — model must comply

**Observed:**

```elixir
%{
  text: "I don't have real-time data access without tools, so I can't provide the current price of Bitcoin. For a quick estimate, you can check a financial news site or a cryptocurrency exchange.",
  kind: :plain_text
}
```

---

### #20 `latest_version_recency` — PASS

> 'latest' implies recency → engage tools, not plain text

**Observed:**

```elixir
%{
  names: ["web_search"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{"query" => "latest stable macOS version and release date"},
      name: "web_search"
    }
  ]
}
```

---

### #21 `changed_mind_cancel` — PASS

> user explicitly drops the active task → cancel_task

**Observed:**

```elixir
%{
  names: ["cancel_task"],
  kind: :tool_calls,
  calls: [%{args: %{"task_num" => 1}, name: "cancel_task"}]
}
```

---

### #22 `multi_attachment_compare` — PASS

> 3 fresh attachments → engage tools

**Observed:**

```elixir
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "attachments" => ["workspace/data/q1_report.pdf",
         "workspace/data/q2_report.pdf", "workspace/data/q3_report.pdf"],
        "language" => "en",
        "task_spec" => "Compare the three quarterly reports to identify what changed across them.",
        "task_title" => "Compare quarterly reports",
        "task_type" => "one_off"
      },
      name: "create_task"
    }
  ]
}
```

---

### #23 `dont_teach_explainer_exception` — PASS

> 'how do I…' authorizes how-to plain-text reply

**Observed:**

```elixir
%{
  text: "To send a Slack message via a webhook from the command line, you can use `curl` to make an HTTP POST request to the Slack webhook URL. Here's a step-by-step guide:\n\n### 1. **Obtain the Slack Webhook URL**\n   - Go to your Slack workspace.\n   - Navigate to the channel where you want to post the message.\n   - Click on the channel name, then select **Integrations** > **Add an App**.\n   - Search for **Incoming WebHooks** and add it to your Slack.\n   - Choose the channel and click **Add Incoming WebHo",
  kind: :plain_text
}
```

---

### #24 `verb_on_missing_task` — PASS

> destructive verb on non-existent task_num → don't call it

**Observed:**

```elixir
%{
  text: "There is no task (47) in the current task list. The only active task is (1). If you meant to cancel task (1), let me know.",
  kind: :plain_text
}
```

---

### #26 `mcp_oauth_needs_auth` — PASS

> connect_mcp on OAuth-protected URL → call connect_mcp

**Observed:**

```elixir
%{
  names: ["connect_mcp"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{"auth_method" => "auto", "url" => "http://localhost:45953"},
      name: "connect_mcp"
    }
  ]
}
```

---

### #27 `chain_oauth_callback_resume` — PASS

> Two-chain flow simulating the full OAuth lifecycle:

  Chain 1
    1. Model emits connect_mcp(url) on the bitrix24 mock URL
       (path /mcp).
    2. Runtime walks the discovery cascade (PRM → ASM), mints
       state, builds auth_url, returns
       {status: "needs_auth", auth_url}.
    3. Chain ends (needs_auth is result-terminating).

  OAuth simulation (driven by the runner)
    4. Test hits the auth_url against the bitrix mock with
       `redirect: false`. Mock 302s to the runtime's
       configured redirect_uri with `?code=…&state=…`.
    5. Test parses code+state from the Location header,
       calls Dmhai.Auth.OAuth2.complete_flow(state, code).
    6. Test replicates the production finalize_connection
       body — saves creds, runs MCP handshake to populate
       tools list, registers the service, attaches to anchor.

  Chain 2
    7. Test appends the followup user msg
       ("now use the bitrix tools to ..."). Builds a fresh
       LLM context — `## Authorized MCP services` block now
       carries a row for the bitrix alias.
    8. Model is expected to recognize the now-authorized
       service and either (a) reference it in the answer
       or (b) call a `<alias>.<tool>` namespaced tool.

Pass criteria
  * Chain 1 includes connect_mcp + ends in :terminated_by_tool
  * OAuth simulation succeeds (auth_url → code → tokens)
  * Chain 2 has at least one turn AND mentions
    the bitrix alias OR calls a namespaced tool

Caveat / known gap
  The bitrix24 mock's /mcp endpoint requires a hardcoded
  test API key, not the OAuth-minted token. So step 6's
  MCP handshake hits 401 → registered service has tools=[].
  Chain 2 still sees the alias row in the services block
  (just with no tool list). To fully exercise namespaced
  tool calls, the mock /mcp needs to accept tokens minted
  via /oauth/token as well.


**Observed:**

```elixir
%{
  trace: %{
    final: :terminated_by_tool,
    turns: [
      %{
        kind: :tool_calls,
        results: [
          ok: %{
            alias: "mcp",
            message: "Click the link to authorize. The chat resumes automatically once you complete authorization in the browser.",
            status: "needs_auth",
            auth_url: "http://localhost:45953/oauth/authorize?response_type=code&client_id=app.test123&redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Foauth%2Fcallback&code_challenge=f_71lR0vePiDQoLHFUt-u0BsVOXEL9LC3Wjcb7GpQqY&code_challenge_method=S256&state=zzgI51lyxb57qtWK-DJ_emWTcqQ3Ur3MuSQ41U7h-_Y&resource=http%3A%2F%2Flocalhost%3A45953"
          }
        ],
        calls: [
          %{
            args: %{
              "auth_method" => "auto",
              "url" => "http://localhost:45953/mcp"
            },
            name: "connect_mcp"
          }
        ]
      },
      %{kind: :chain_boundary},
      %{
        kind: :tool_calls,
        results: [
          ok: %{
            alias: "localhost",
            message: "Paste this service's API key and pick which auth header it expects. If you pick the wrong one the server returns 401 and you can retry with another. If this URL isn't an MCP server but a regular REST API or webhook, abandon `connect_mcp` and call the API directly with `run_script` + `curl`.",
            status: "needs_setup",
            form: %{
              "expires_at" => 1777392555946,
              "fields" => [
                %{
                  "label" => "API key",
                  "name" => "api_key",
                  "secret" => true,
                  "type" => "password"
                },
                %{
                  "default" => "Authorization",
                  "label" => "Auth header",
                  "name" => "auth_header",
                  "options" => [
                    %{
                      "label" => "Authorization: Bearer …  (most APIs — Slack, GitHub, OpenAI, HuggingFace, …)",
                      "value" => "Authorization"
                    },
                    %{"label" => "x-api-key  (generic)", "value" => "x-api-key"},
                    %{
                      "label" => "x-consumer-api-key  (Composio)",
                      "value" => "x-consumer-api-key"
                    }
                  ],
                  "secret" => false,
                  "type" => "select"
                }
              ],
              "kind" => "connect_mcp_setup",
              "setup_payload" => %{
                "alias" => "localhost",
                "anchor_task_id" => "QNT-4HIVRouX",
                "auth_method" => "api_key",
                "server_url" => "http://localhost:45953"
              },
              "submit_label" => "Connect",
              "submitted" => false,
              "submitted_at" => nil,
              "token" => "_54zrgYSXbwZB6tVRn2slg",
              "values_meta" => nil
            }
          }
        ],
        calls: [
          %{
            args: %{"auth_method" => "auto", "url" => "http://localhost:45953"},
            name: "connect_mcp"
          }
        ]
      }
    ],
    turn_count: 3
  },
  kind: :chain,
  turn_count: 3
}
```

---

### #28 `mcp_api_key_needs_setup` — PASS

> connect_mcp on api-key MCP URL

**Observed:**

```elixir
%{
  names: ["connect_mcp"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{"auth_method" => "auto", "url" => "http://localhost:9091/mcp"},
      name: "connect_mcp"
    }
  ]
}
```

---

### #29 `request_input_two_fields` — PASS

> ≥2 cred fields needed → request_input with all fields populated

**Observed:**

```elixir
%{
  text: "To set up the OAuth credentials for your internal API, I'll need the following details:\n\n1. **Client ID**: The OAuth client ID provided for your API.\n2. **Client Secret**: The OAuth client secret associated with the client ID.\n\nPlease provide these details, and I'll save them securely for future use.",
  kind: :plain_text
}
```

---

### #30 `request_input_single_field_uses_text` — PASS

> single-field cred ask → plain text, NOT request_input

**Observed:**

```elixir
%{
  text: "Could you clarify what you'd like me to do with OpenAI? For example:\n\n- Do you want to generate text, images, or code using OpenAI's API?\n- Do you need help setting up or configuring an OpenAI API call?\n- Are you looking for a specific model or endpoint (e.g., GPT-4, DALL·E, Whisper)?",
  kind: :plain_text
}
```

---

### #32 `request_input_multi_field_config` — PASS

> ≥2 non-secret config fields → request_input

**Observed:**

```elixir
%{
  names: ["request_input"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "fields" => [
          %{"label" => "SMTP Host", "name" => "host", "type" => "text"},
          %{"label" => "SMTP Port", "name" => "port", "type" => "text"},
          %{
            "label" => "From Address",
            "name" => "from_address",
            "type" => "text"
          },
          %{
            "label" => "Reply-To Address",
            "name" => "reply_to_address",
            "type" => "text"
          }
        ],
        "submit_label" => "Submit"
      },
      name: "request_input"
    }
  ]
}
```

---

### #33 `request_input_two_inputs_borderline` — PASS

> borderline 2 light-stakes inputs (name + email) → request_input

**Observed:**

```elixir
%{
  names: ["request_input"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "fields" => [
          %{
            "label" => "Display Name",
            "name" => "display_name",
            "type" => "text"
          },
          %{
            "label" => "Email Address",
            "name" => "email_address",
            "type" => "text"
          }
        ],
        "submit_label" => "Submit"
      },
      name: "request_input"
    }
  ]
}
```

---

### #34 `open_ended_uses_prose` — PASS

> open-ended question → plain text, NOT request_input

**Observed:**

```elixir
%{
  text: "Here are a few name ideas for your side project:\n\n1. **Nova**\n2. **Pulse**\n3. **Echo**\n4. **Flare**\n5. **Zenith**\n6. **Mirage**\n7. **Rift**\n8. **Lumen**\n9. **Apex**\n10. **Vista**",
  kind: :plain_text
}
```

---

### #35 `chain_mcp_connect_oauth_needs_auth` — PASS

> End-to-end MCP connect against the OAuth-publishing bitrix24
mock. Single tool-call turn:
  1. Model emits connect_mcp(url: "<bitrix>/mcp").
  2. Runtime tries MCP at that path → mock returns 401 with
     WWW-Authenticate: Bearer.
  3. Runtime walks /.well-known/oauth-protected-resource →
     /.well-known/oauth-authorization-server, mints state,
     builds auth_url, and returns
     {status: "needs_auth", auth_url, ...}.
  4. Tool result is chain-terminating → chain ends with
     final = :terminated_by_tool. The model never gets a
     follow-up turn (production behavior: runtime captures
     the auth_url, persists state, emits a synthetic
     assistant message with the link).

Pass criteria:
  * connect_mcp appears in the chain
  * URL passed to connect_mcp contains "localhost" + "/mcp"
  * final = :terminated_by_tool (NOT plain_text, NOT
    max_turns — must be the tool result that ends it)


**Observed:**

```elixir
%{
  trace: %{
    final: :terminated_by_tool,
    turns: [
      %{
        kind: :tool_calls,
        results: [
          ok: %{
            alias: "mcp",
            message: "Paste this service's API key and pick which auth header it expects. If you pick the wrong one the server returns 401 and you can retry with another. If this URL isn't an MCP server but a regular REST API or webhook, abandon `connect_mcp` and call the API directly with `run_script` + `curl`.",
            status: "needs_setup",
            form: %{
              "expires_at" => 1777392574591,
              "fields" => [
                %{
                  "label" => "API key",
                  "name" => "api_key",
                  "secret" => true,
                  "type" => "password"
                },
                %{
                  "default" => "Authorization",
                  "label" => "Auth header",
                  "name" => "auth_header",
                  "options" => [
                    %{
                      "label" => "Authorization: Bearer …  (most APIs — Slack, GitHub, OpenAI, HuggingFace, …)",
                      "value" => "Authorization"
                    },
                    %{"label" => "x-api-key  (generic)", "value" => "x-api-key"},
                    %{
                      "label" => "x-consumer-api-key  (Composio)",
                      "value" => "x-consumer-api-key"
                    }
                  ],
                  "secret" => false,
                  "type" => "select"
                }
              ],
              "kind" => "connect_mcp_setup",
              "setup_payload" => %{
                "alias" => "mcp",
                "anchor_task_id" => "ojZy9foCHSoG",
                "auth_method" => "api_key",
                "server_url" => "http://localhost:45953/mcp"
              },
              "submit_label" => "Connect",
              "submitted" => false,
              "submitted_at" => nil,
              "token" => "vpBY0RVuCFk2YF8H8BzkRg",
              "values_meta" => nil
            }
          }
        ],
        calls: [
          %{
            args: %{
              "auth_method" => "auto",
              "url" => "http://localhost:45953/mcp"
            },
            name: "connect_mcp"
          }
        ]
      }
    ],
    turn_count: 1
  },
  kind: :chain,
  turn_count: 1
}
```

---

### #36 `chain_request_input_terminates` — PASS

> Verifies request_input is chain-terminating. After the model
emits request_input(fields: [...]), the chain must NOT
continue with another LLM call — production captures the
preceding narration, persists the form, and ends the chain
until the user submits.

Setup: user asks for paired credentials so the model is
expected to call request_input.

Chain expectation:
  * exactly ONE tool-calls turn (containing request_input)
  * final state == :terminated_by_tool
  * NO subsequent plain-text turn (the chain stops cold)


**Observed:**

```elixir
%{
  trace: %{
    final: :terminated_by_tool,
    turns: [
      %{
        kind: :tool_calls,
        results: [:not_executed_call_terminating],
        calls: [
          %{
            args: %{
              "fields" => [
                %{
                  "label" => "Client ID",
                  "name" => "client_id",
                  "type" => "text"
                },
                %{
                  "label" => "Client Secret",
                  "name" => "client_secret",
                  "type" => "password"
                }
              ],
              "submit_label" => "Submit"
            },
            name: "request_input"
          }
        ]
      }
    ],
    turn_count: 1
  },
  kind: :chain,
  turn_count: 1
}
```

---

### #31 `save_creds_payload_shape` — PASS

> save_creds called with target/kind/nested-payload of correct shape

**Observed:**

```elixir
%{
  names: ["save_creds"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "kind" => "api_key",
        "payload" => %{"value" => "sk-test-abc12345"},
        "target" => "openai_api"
      },
      name: "save_creds"
    }
  ]
}
```