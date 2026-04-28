# Prompt scenarios — `devstral-2:123b-cloud`

Generated: 2026-04-28T16:01:12.448139Z

Prompt: _live `SystemPrompt.assistant_base/0`_

Pass: **35/35**

## Summary

| # | Scenario | Result | Duration | Reason |
|---|---|---|---|---|
| 1 | `chitchat` | PASS | 1283ms |  |
| 2 | `knowledge_static_fact` | PASS | 858ms |  |
| 3 | `live_event_create_task` | PASS | 1662ms |  |
| 4 | `webhook_not_mcp` | PASS | 1344ms |  |
| 5 | `mcp_real` | PASS | 992ms |  |
| 6 | `fresh_attachment_extract` | PASS | 1527ms |  |
| 7 | `historical_attachment_gist` | PASS | 2212ms |  |
| 8 | `historical_attachment_verbatim` | PASS | 1479ms |  |
| 9 | `pivot_off_topic` | PASS | 875ms |  |
| 10 | `pivot_accept_pause` | PASS | 964ms |  |
| 11 | `refine_anchor` | PASS | 1472ms |  |
| 12 | `dont_teach_use_tool` | PASS | 2937ms |  |
| 13 | `ssh_provision_first` | PASS | 1044ms |  |
| 14 | `save_creds_on_paste` | PASS | 1275ms |  |
| 15 | `periodic_completion` | PASS | 1117ms |  |
| 16 | `no_bookkeeping_in_text` | PASS | 1094ms |  |
| 17 | `ambiguous_refine_or_new` | PASS | 1108ms |  |
| 18 | `multi_axis_overload` | PASS | 1837ms |  |
| 19 | `adversarial_override_no_task` | PASS | 1375ms |  |
| 20 | `latest_version_recency` | PASS | 1276ms |  |
| 21 | `changed_mind_cancel` | PASS | 1132ms |  |
| 22 | `multi_attachment_compare` | PASS | 2109ms |  |
| 23 | `dont_teach_explainer_exception` | PASS | 6047ms |  |
| 24 | `verb_on_missing_task` | PASS | 2137ms |  |
| 26 | `mcp_oauth_needs_auth` | PASS | 1188ms |  |
| 27 | `chain_oauth_callback_resume` | PASS | 2410ms |  |
| 28 | `mcp_api_key_needs_setup` | PASS | 1033ms |  |
| 29 | `request_input_two_fields` | PASS | 1863ms |  |
| 30 | `request_input_single_field_uses_text` | PASS | 1433ms |  |
| 32 | `request_input_multi_field_config` | PASS | 1873ms |  |
| 33 | `request_input_two_inputs_borderline` | PASS | 1479ms |  |
| 34 | `open_ended_uses_prose` | PASS | 1941ms |  |
| 35 | `chain_mcp_connect_oauth_needs_auth` | PASS | 1114ms |  |
| 36 | `chain_request_input_terminates` | PASS | 3329ms |  |
| 31 | `save_creds_payload_shape` | PASS | 1214ms |  |

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
    %{args: %{"url" => "https://huggingface.co/mcp"}, name: "connect_mcp"}
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
        "task_spec" => "Summarize the content of the attached quarterly report.",
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
  text: "The report also covers:\n\n- **Operational metrics**: Customer churn dropped 5% quarter-over-quarter, and average deal size grew 8%.\n- **Product updates**: Edge runtime v2 shipped with a 30% smaller footprint and a new plugin system.\n- **Team growth**: Eight hires across engineering and customer success, with a focus on expanding the support team.\n- **Roadmap**: Plans for a Q4 beta of the real-time analytics dashboard and a security audit for the core platform.",
  kind: :plain_text
}
```

---

### #8 `historical_attachment_verbatim` — PASS

> file NOT in `## Recently-extracted files`, verbatim Q → re-extract

**Observed:**

```elixir
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "attachments" => ["workspace/old_contract.pdf"],
        "language" => "en",
        "task_spec" => "for old_contract.pdf — what is the EXACT wording of clause 3?",
        "task_title" => "Extract clause 3 wording",
        "task_type" => "one_off"
      },
      name: "create_task"
    }
  ]
}
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
%{
  names: ["pause_task"],
  kind: :tool_calls,
  calls: [%{args: %{"task_num" => 1}, name: "pause_task"}]
}
```

---

### #11 `refine_anchor` — PASS

> anchor set + on-topic clarification → continue, NOT create_task

**Observed:**

```elixir
%{
  names: ["run_script"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "script" => "curl -X POST \"https://example.bitrix24.de/rest/1/x/\" -H \"Content-Type: application/json\" -d '{\"fields\": {\"TITLE\": \"New Deal\", \"CATEGORY_ID\": 2}}'"
      },
      name: "run_script"
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
  text: "I'm currently on task (1) — Scrape example.com title. Want me to pause / cancel / stop it and handle your new request first, or finish (1) before getting to it?",
  kind: :plain_text
}
```

---

### #18 `multi_axis_overload` — PASS

> fresh attachment + cred paste + live-event ask in one msg → tool calls

**Observed:**

```elixir
%{
  names: ["create_task"],
  kind: :tool_calls,
  calls: [
    %{
      args: %{
        "attachments" => ["workspace/data/openai_audit.csv"],
        "language" => "en",
        "task_spec" => "Extract content from the attached openai_audit.csv file and determine which OpenAI model is currently fastest according to their status page.",
        "task_title" => "Extract content from openai_audit.csv and check OpenAI model status",
        "task_type" => "one_off"
      },
      name: "create_task"
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
  text: "I don't have real-time data access without a task. For a quick estimate, you can check a financial news site or use a search engine.",
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
      args: %{"query" => "latest stable macOS version release date"},
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
  text: "To send a Slack message via a webhook from the command line, you can use `curl` to make a POST request to the Slack webhook URL. Here's a step-by-step guide:\n\n### 1. **Obtain the Slack Webhook URL**\n   - Go to your Slack workspace.\n   - Navigate to the channel where you want to post the message.\n   - Click on the channel name, then select **\"Integrations\"** > **\"Add an App\"**.\n   - Search for **\"Incoming WebHooks\"** and add it to your workspace.\n   - Choose the channel and click **\"Add Incoming ",
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
            auth_url: "http://localhost:45953/oauth/authorize?response_type=code&client_id=app.test123&redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Foauth%2Fcallback&code_challenge=UIQYEUdXbSekk5g5CdnEmwRRVmIDWY4XT-7wofhj26Y&code_challenge_method=S256&state=uqGpLXEQHQO-t31fKB5GKMf7DOooONIruZkhl1uayzU&resource=http%3A%2F%2Flocalhost%3A45953"
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
              "expires_at" => 1777392648147,
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
                "anchor_task_id" => "JOZ70Prkd7b_",
                "auth_method" => "api_key",
                "server_url" => "http://localhost:45953"
              },
              "submit_label" => "Connect",
              "submitted" => false,
              "submitted_at" => nil,
              "token" => "5Ka7QUZGKPydWjtpShUs4A",
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
  calls: [%{args: %{"url" => "http://localhost:9091/mcp"}, name: "connect_mcp"}]
}
```

---

### #29 `request_input_two_fields` — PASS

> ≥2 cred fields needed → request_input with all fields populated

**Observed:**

```elixir
%{
  text: "To call your internal API, I need the OAuth `client_id` and `client_secret`. Could you provide these credentials? Once I have them, I can proceed with setting up the API call.",
  kind: :plain_text
}
```

---

### #30 `request_input_single_field_uses_text` — PASS

> single-field cred ask → plain text, NOT request_input

**Observed:**

```elixir
%{
  text: "Could you clarify what you'd like me to do with OpenAI? For example:\n\n- Generate text or code using a specific model?\n- Access a specific OpenAI API or service?\n- Retrieve information or perform a task using OpenAI's tools?",
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
  text: "Here are a few name ideas for your side project:\n\n1. **Nova**\n2. **Pulse**\n3. **Echo**\n4. **Flare**\n5. **Zenith**\n6. **Mirage**\n7. **Rift**\n8. **Aura**\n9. **Vertex**\n10. **Lumen**",
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
              "expires_at" => 1777392665898,
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
                "anchor_task_id" => "LMEdmjmUz6VN",
                "auth_method" => "api_key",
                "server_url" => "http://localhost:45953/mcp"
              },
              "submit_label" => "Connect",
              "submitted" => false,
              "submitted_at" => nil,
              "token" => "KLG2hLeFDWP9ju0gx_V2rw",
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