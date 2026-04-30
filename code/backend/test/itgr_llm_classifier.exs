# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.LLMClassifier do
  use ExUnit.Case, async: true

  alias Dmhai.Agent.LLM

  describe "looks_like_server_error?/1" do
    test "matches transient overload markers" do
      assert LLM.looks_like_server_error?("Server overloaded, please retry shortly (ref: abc-123)")
      assert LLM.looks_like_server_error?("server is overloaded right now")
      assert LLM.looks_like_server_error?("Service Unavailable")
      assert LLM.looks_like_server_error?("HTTP 503: temporarily unavailable")
      assert LLM.looks_like_server_error?("Internal server error")
      assert LLM.looks_like_server_error?("upstream returned 502 Bad Gateway")
      assert LLM.looks_like_server_error?("please retry shortly")
    end

    test "does NOT match rate-limit / quota errors" do
      refute LLM.looks_like_server_error?("rate limit reached")
      refute LLM.looks_like_server_error?("Too Many Requests")
      refute LLM.looks_like_server_error?("weekly usage limit exceeded")
      refute LLM.looks_like_server_error?("quota exhausted")
    end

    test "does NOT match malformed-request / format errors" do
      refute LLM.looks_like_server_error?(~s|Expected last role User or Tool but got assistant|)
      refute LLM.looks_like_server_error?("Invalid argument: missing field 'name'")
      refute LLM.looks_like_server_error?("Function call is missing a thought_signature")
      refute LLM.looks_like_server_error?("model not found")
    end

    test "non-strings safely return false" do
      refute LLM.looks_like_server_error?(nil)
      refute LLM.looks_like_server_error?(42)
      refute LLM.looks_like_server_error?(%{})
    end
  end
end
