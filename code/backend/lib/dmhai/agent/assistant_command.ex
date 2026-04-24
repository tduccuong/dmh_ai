# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.AssistantCommand do
  @moduledoc """
  Canonical command for the Assistant pipeline.

  The Assistant classifier is a text-only router — it sees the stored user
  message (which, if attachments are present, already contains a
  `[Attached files]\\n- workspace/<name>` block injected at /agent/chat
  entry) and routes the message to one of the management tools. It does
  NOT see inline image bytes: the Assistant Loop processes pixels via
  `extract_content` when it runs the task.

  Separation: this struct carries **only** the fields the Assistant
  path needs. There is no `images`, no `has_video`, no `task_id` —
  those belong to Confidant (inline images) or are unused here.
  """

  @enforce_keys [:type, :content, :session_id, :reply_pid]
  defstruct [
    # :chat — normal user message.
    # :interrupt is delivered via UserAgent as a plain atom, not a command.
    :type,

    # The user's message text. If the request carried attachments, the
    # `/agent/chat` handler has already persisted a user message to
    # session.messages whose content includes `📎 workspace/<name>` lines
    # for each attachment — the model sees those lines verbatim in history.
    :content,

    # Which session this command belongs to (provided by the HTTP handler).
    :session_id,

    # The pid that receives {:chunk, text}, {:done, result}, {:error, reason}.
    :reply_pid,

    # Filenames of scaled-down attachments that were uploaded to the session
    # workspace at attach time. The HTTP handler uses these to wait for
    # uploads to land (safety net) and to inject workspace/<name> paths into
    # the stored user message BEFORE dispatching to the Assistant.
    attachment_names: [],

    # Attached files delivered inline as extracted text (e.g. a .txt the FE
    # read client-side). Kept for future pipeline variants that would
    # inject snippets into the context; the current pipeline does not.
    files: [],

    # Adapter-specific extras (e.g. %{telegram_message_id: 42})
    metadata: %{}
  ]
end
