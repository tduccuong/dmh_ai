# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Command do
  @moduledoc """
  Canonical command format. Every adapter (HTTP, Telegram, …) translates its
  incoming message into a Command before handing it to the UserAgent.
  """

  @enforce_keys [:type, :content, :session_id, :reply_pid]
  defstruct [
    # :chat — normal user message
    # :interrupt — cancel the current running task
    :type,

    # The user's message text
    :content,

    # Which session this command belongs to (provided by the adapter)
    :session_id,

    # The pid that receives {:chunk, text}, {:done, result}, {:error, reason}
    :reply_pid,

    # Base64-encoded images for the current message (photos + video frames).
    # Injected into the LLM message at call time; NOT stored in the session DB.
    images: [],

    # Original filenames corresponding to each entry in `images` (same order).
    # Used when storing descriptions in the image_descriptions table.
    image_names: [],

    # Attached files: list of %{"name" => name, "content" => extracted_text}.
    # Content is injected into the LLM message; filename/snippet stored in DB.
    files: [],

    # True when `images` contains video frames (not photos).
    # Triggers the video-frame hint in the system prompt.
    has_video: false,

    # Pre-allocated job_id for Assistant path with attachments.
    # FE reserves this via GET /reserve-job-id before uploading, so the
    # workspace path is known and uploads can run in parallel with the LLM call.
    # nil for Confidant path and attachment-less Assistant requests.
    job_id: nil,

    # Filenames of scaled-down attachments uploaded to the job workspace.
    # Used by handle_handoff_to_worker to wait for uploads and inject paths.
    attachment_names: [],

    # Adapter-specific extras (e.g. %{telegram_message_id: 42})
    metadata: %{}
  ]
end
