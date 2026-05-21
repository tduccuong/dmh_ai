# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.SourceScopeTest do
  @moduledoc """
  Pins the `DmhAi.VectorDB.SourceScope` classifier + the
  retrieval-time scope filter. The bug class this exists to
  prevent: an org indexes third-party SaaS API docs, the
  generic auto-fetch returns hits from those, and the model
  conflates the third-party API with DMH-AI's runtime primitives.

  See arch_wiki/dmh_ai/knowledge.md §Source scope.
  """

  use ExUnit.Case, async: false

  alias DmhAi.VectorDB.SourceScope

  describe "SourceScope.from_url/1" do
    test "matches known third-party SaaS hostnames" do
      assert ~s({"category":"api-docs","platform":"bitrix24"})         = SourceScope.from_url("https://helpdesk.bitrix24.com/x") |> normalise()
      assert ~s({"category":"api-docs","platform":"hubspot"})          = SourceScope.from_url("https://api.hubapi.com/y")        |> normalise()
      assert ~s({"category":"api-docs","platform":"google_workspace"}) = SourceScope.from_url("https://googleapis.com/admin")   |> normalise()
      assert ~s({"category":"api-docs","platform":"m365"})             = SourceScope.from_url("https://graph.microsoft.com/v1") |> normalise()
      assert ~s({"category":"api-docs","platform":"calendly"})         = SourceScope.from_url("https://api.calendly.com/events")|> normalise()
      assert ~s({"category":"api-docs","platform":"salesforce"})       = SourceScope.from_url("https://acme.my.salesforce.com") |> normalise()
    end

    test "unknown hostname → nil (counts as untagged)" do
      assert SourceScope.from_url("https://example.com/page") == nil
      assert SourceScope.from_url("https://acme-internal.io/handbook") == nil
    end

    test "non-URL input → nil" do
      assert SourceScope.from_url("just a string")        == nil
      assert SourceScope.from_url("/local/path/file.pdf") == nil
      assert SourceScope.from_url(nil)                    == nil
      assert SourceScope.from_url(123)                    == nil
    end
  end

  describe "SourceScope.decode/1" do
    test "round-trips an encoded scope" do
      encoded = SourceScope.encode("hubspot", "api-docs")
      assert SourceScope.decode(encoded) == %{"platform" => "hubspot", "category" => "api-docs"}
    end

    test "nil / empty / invalid → nil" do
      assert SourceScope.decode(nil) == nil
      assert SourceScope.decode("")  == nil
      assert SourceScope.decode("not json") == nil
    end
  end

  describe "third_party_platforms/0" do
    test "lists every distinct platform from the hostname table" do
      platforms = SourceScope.third_party_platforms()

      assert "bitrix24"         in platforms
      assert "hubspot"          in platforms
      assert "google_workspace" in platforms
      assert "m365"             in platforms
      assert "calendly"         in platforms

      # No duplicates (the table maps multiple hostnames to the
      # same slug; the helper must dedupe).
      assert length(platforms) == length(Enum.uniq(platforms))
    end
  end

  describe "compile_mode_predicate/0" do
    test "excludes all known third-party platforms + keeps untagged" do
      pred = SourceScope.compile_mode_predicate()
      assert pred.include_untagged == true
      assert "bitrix24" in pred.platforms_not_in
      assert "hubspot" in pred.platforms_not_in
    end
  end

  # `Jason.encode!` doesn't guarantee key order; the SourceScope
  # encoder builds a plain map, so the JSON's key order is
  # implementation-defined. Normalise to a sorted-key form for
  # cross-version stability.
  defp normalise(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Enum.sort()
    |> Map.new()
    |> Jason.encode!()
  end
end
