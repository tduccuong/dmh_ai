# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ConfidantCommand do
  @moduledoc """
  Canonical command for the Confidant pipeline.

  Confidant is the fast synchronous Q&A path — a single streaming LLM call
  per user message, no tasks, no async loop. It uses inline image bytes
  directly for vision answering; that's its whole purpose.

  Separation: this struct carries **only** the fields the Confidant path
  needs. There is no `attachment_names` (Confidant does not spawn a loop
  that would read from `workspace/`).
  """

  @enforce_keys [:type, :content, :session_id, :reply_pid]
  defstruct [
    # :chat — normal user message.
    # :interrupt is delivered via UserAgent as a plain atom, not a command.
    :type,

    # The user's message text.
    :content,

    # Which session this command belongs to (provided by the HTTP handler).
    :session_id,

    # The pid that receives {:chunk, text}, {:done, result}, {:error, reason}.
    :reply_pid,

    # Base64-encoded images for the current message (photos + video frames).
    # Injected into the LLM message at call time for direct vision answering.
    images: [],

    # Original filenames corresponding to each entry in `images` (same order).
    # Used when storing / retrieving descriptions in the image_descriptions table.
    image_names: [],

    # Attached files: list of %{"name" => name, "content" => extracted_text}.
    # Content is injected into the LLM message; filename/snippet stored in DB.
    files: [],

    # True when `images` contains video frames (not photos).
    # Triggers the video-frame hint in the system prompt.
    has_video: false,

    # Adapter-specific extras (e.g. %{telegram_message_id: 42})
    metadata: %{}
  ]
end
