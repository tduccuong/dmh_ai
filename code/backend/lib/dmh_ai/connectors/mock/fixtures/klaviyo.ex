# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.Fixtures.Klaviyo do
  @moduledoc """
  Deterministic, fixture-specific canned responses for the Mock
  Vendor MCP server, shaped for the Klaviyo connector functions.

  Klaviyo's MCP server is vendor-hosted (Klaviyo runs it themselves),
  so there is no in-process REST translator and no `mcp_handler_module`
  on the connector. This fixture exists so test suites that want to
  assert against a stable Klaviyo-shaped response (sentinel ids
  unlikely to collide with real Klaviyo records) have something to
  point at.

  Unlike Asana's fixture (which keeps Klaviyo's JSON:API `"data"`
  envelope), these return already-mapped shapes — `{profiles: [...]}`,
  `{profile_id: "..."}`, etc. — matching what the vendor MCP exposes
  to callers downstream of the JSON:API translation.

  Sentinel identifiers (obviously-fake Klaviyo profile / event / list /
  campaign ids + a fake profile email) let runbooks + tests assert
  mechanically that the chain's output came from the connector path.
  """

  @doc """
  Fixture map passed to `Mock.VendorMCPServer.start_link(fixtures: …)`.
  """
  @spec fixtures() :: %{required(String.t()) => (map() -> map()) | map()}
  def fixtures do
    %{
      "profile.find"        => &profile_find/1,
      "profile.create"      => &profile_create/1,
      "profile.update"      => &profile_update/1,
      "event.create"        => &event_create/1,
      "event.find"          => &event_find/1,
      "list.find"           => &list_find/1,
      "list.create"         => &list_create/1,
      "list.add_profile"    => &list_add_profile/1,
      "list.remove_profile" => &list_remove_profile/1,
      "campaign.find"       => &campaign_find/1,
      "segment.find"        => &segment_find/1,
      "flow.find"           => &flow_find/1,
      "template.find"       => &template_find/1,
      "metric.find"         => &metric_find/1
    }
  end

  @doc """
  Sentinel strings unique to this fixture.
  """
  def sentinels do
    %{
      profile_id:    "01MOCKPROFILE001",
      profile_email: "klara.beispiel@beispiel-shop-demo.example",
      event_id:      "01MOCKEVENT0001",
      event_id_2:    "MOCKEVENT002",
      list_id:       "MOCKLIST001",
      list_new_id:   "MOCKLIST002",
      campaign_id:   "01MOCKCAMP00001",
      segment_id:    "MOCKSEGMENT001",
      flow_id:       "MOCKFLOW001",
      template_id:   "MOCKTEMPLATE001",
      metric_id:     "MOCKMETRIC001"
    }
  end

  # ── Per-function fixtures (already-mapped shapes; no JSON:API envelope) ─

  defp profile_find(_args) do
    %{profile_id: id, profile_email: email} = sentinels()

    %{
      "profiles" => [
        %{
          "id"    => id,
          "email" => email
        }
      ]
    }
  end

  defp profile_create(_args) do
    %{profile_id: id} = sentinels()

    %{
      "profile_id" => id <> Integer.to_string(:erlang.unique_integer([:positive]))
    }
  end

  defp profile_update(_args) do
    %{profile_id: id} = sentinels()

    %{"profile_id" => id}
  end

  defp event_create(_args) do
    %{event_id: id} = sentinels()

    %{"event_id" => id}
  end

  defp list_find(_args) do
    %{list_id: id} = sentinels()

    %{
      "lists" => [
        %{
          "id"   => id,
          "name" => "Beispiel-Liste Demo"
        }
      ]
    }
  end

  defp campaign_find(_args) do
    %{campaign_id: id} = sentinels()

    %{
      "campaigns" => [
        %{
          "id"     => id,
          "name"   => "Beispiel-Kampagne Demo",
          "status" => "Draft"
        }
      ]
    }
  end

  defp list_create(_args) do
    %{list_new_id: id} = sentinels()

    %{"list_id" => id}
  end

  defp list_add_profile(_args), do: %{"ok" => true}

  defp list_remove_profile(_args), do: %{"ok" => true}

  defp segment_find(_args) do
    %{segment_id: id} = sentinels()

    %{
      "segments" => [
        %{
          "id"   => id,
          "name" => "Beispiel-Segment Demo"
        }
      ]
    }
  end

  defp flow_find(_args) do
    %{flow_id: id} = sentinels()

    %{
      "flows" => [
        %{
          "id"     => id,
          "name"   => "Beispiel-Flow Demo",
          "status" => "live"
        }
      ]
    }
  end

  defp template_find(_args) do
    %{template_id: id} = sentinels()

    %{
      "templates" => [
        %{
          "id"   => id,
          "name" => "Beispiel-Template Demo"
        }
      ]
    }
  end

  defp metric_find(_args) do
    %{metric_id: id} = sentinels()

    %{
      "metrics" => [
        %{
          "id"   => id,
          "name" => "Placed Order"
        }
      ]
    }
  end

  defp event_find(_args) do
    %{event_id: id1, event_id_2: id2} = sentinels()

    %{
      "events" => [
        %{"id" => id1, "metric" => "Placed Order"},
        %{"id" => id2, "metric" => "Opened Email"}
      ]
    }
  end
end
