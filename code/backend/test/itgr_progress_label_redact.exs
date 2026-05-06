defmodule Itgr.ProgressLabelRedact do
  @moduledoc """
  Regression: `ProgressLabel.format/2` was leaking OAuth bearer tokens
  into `session_progress.label` (DB-persisted) and the FE activity row,
  because the script preview was truncated WITHOUT going through
  `DmhAi.Util.Redact`. Tokens that should never have left the runtime
  ended up sitting in plain text in the database and on screen.

  Locks the redact-before-truncate invariant so a future refactor can't
  silently regress it.

  ## Note on test fixtures

  Every "leaked" credential string in this file is a FAKE built by
  concatenating two literals at runtime — for example
  `"ya29." <> "FAKE_TOKEN_FOR_REGRESSION_TEST_..."`. The source code
  therefore never contains a complete-looking access token in a single
  string literal. This avoids tripping repo-side secret scanners
  (GitHub Push Protection, GitGuardian, gitleaks) on what would
  otherwise look like a leaked Google OAuth or GitHub PAT.
  """

  use ExUnit.Case, async: true

  alias DmhAi.Agent.ProgressLabel

  # Body chosen to satisfy BOTH redact patterns the tests cover:
  #   * Google ya29 — `[A-Za-z0-9_\-]{20,}`
  #   * GitHub PAT  — `[A-Za-z0-9]{30,}` (no underscores allowed)
  # So the body is purely alphanumeric, ≥30 chars, and unmistakably
  # non-real (literal words FAKE / TEST + a long run of `x`). A human
  # eyeballing the file can tell at a glance.
  @fake_body "FAKETOKENFORREGRESSIONTEST" <> "xxxxxxxxxxxxxxxxxxxxxxxxx"

  describe "format/2 — run_script with embedded credentials" do
    test "Google OAuth bearer token is replaced with the redacted sentinel" do
      ya29_token = "ya29." <> @fake_body

      args = %{
        "script" => """
        # Fetch upcoming events from Google Calendar
        ACCESS_TOKEN="#{ya29_token}"
        curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$API_URL"
        """
      }

      label = ProgressLabel.format("run_script", args)

      refute label =~ ya29_token
      assert label =~ "ya29.<redacted>"
    end

    test "Authorization: Bearer header inline in the script is redacted" do
      ya29_token = "ya29." <> @fake_body

      args = %{
        "script" => """
        curl -s -X GET "$API_URL" \\
          -H "Authorization: Bearer #{ya29_token}"
        """
      }

      label = ProgressLabel.format("run_script", args)

      refute label =~ ya29_token
    end

    test "GitHub PAT inside TOKEN= shell assignment is redacted" do
      pat = "ghp_" <> @fake_body

      args = %{"script" => ~s|export GH_TOKEN="#{pat}"|}

      label = ProgressLabel.format("run_script", args)

      # The shell-assignment pattern (`TOKEN=`) fires before the
      # github-PAT-specific pattern, so the replacement here is the
      # generic `<redacted>` sentinel — the leak is still gone, which
      # is the only invariant this test cares about.
      refute label =~ pat
    end

    test "naked GitHub PAT (no surrounding TOKEN=) is redacted via PAT pattern" do
      pat = "ghp_" <> @fake_body

      args = %{"script" => "echo " <> pat}

      label = ProgressLabel.format("run_script", args)

      refute label =~ pat
      assert label =~ "<redacted-github-token>"
    end

    test "non-secret content passes through unchanged (modulo truncate)" do
      args = %{
        "script" => "echo hello world from the runtime"
      }

      label = ProgressLabel.format("run_script", args)

      assert label =~ "echo hello world"
      refute label =~ "<redacted>"
    end
  end
end
