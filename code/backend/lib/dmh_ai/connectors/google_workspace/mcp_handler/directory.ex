# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.MCPHandler.Directory do
  @moduledoc """
  Google Workspace Directory surface — `directory.users.find_by_email`.
  Identity pivot used by other surfaces to resolve an email to a
  Directory user id.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec

  @directory_base "https://admin.googleapis.com/admin/directory/v1"

  @spec function_specs() :: %{required(String.t()) => FunctionSpec.t()}
  def function_specs do
    %{
      "directory.users.find_by_email" => %FunctionSpec{
        method:  :get,
        url:     &directory_users_find_by_email_url/1,
        response: &directory_users_find_by_email_response/2,
        doc:     "Look up a Workspace directory user by email (GET /admin/directory/v1/users/{email}). Identity pivot."
      }
    }
  end

  # ─── directory.users.find_by_email — GET /users/{email} ──────────────

  # vendor: GET /admin/directory/v1/users/{userKey}
  # docs:   https://developers.google.com/admin-sdk/directory/reference/rest/v1/users/get
  # The Directory API accepts the primary email as `userKey` and
  # returns the full Directory user resource. The whole body is
  # surfaced as `%{"user" => body}` so downstream `{{N.user.id}}`
  # references pick up the Directory numeric user id.
  defp directory_users_find_by_email_url(args),
    do: "#{@directory_base}/users/#{safe_email_segment(args["email"])}"

  defp directory_users_find_by_email_response(s, body) when s in 200..299 do
    {:ok, %{"user" => body}}
  end

  # Emails used as a path segment go through `URI.encode_www_form/1`
  # rather than a strict path-id whitelist — the whitelist would
  # reject `@` and `.`, and broadening it for one verb would also
  # broaden it for every id-keyed verb. `@` + `.` are URI-safe so
  # encoding is mostly a no-op, but `+` aliases (`klara+demo@…`) and
  # any unicode local-parts get correctly percent-encoded.
  defp safe_email_segment(email), do: URI.encode_www_form(to_string(email))
end
