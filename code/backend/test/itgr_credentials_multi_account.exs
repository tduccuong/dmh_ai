defmodule Itgr.CredentialsMultiAccount do
  @moduledoc """
  Locks the multi-account credential schema + lookup API:

    * Schema accepts multiple rows with the same `(user_id, target)`
      when `account` differs.
    * `lookup/3` is account-scoped.
    * `lookup_all/2` returns every account row for the target.
    * `delete/3` is account-scoped; `delete_all/2` clears every
      account.
    * `lookup_creds` tool returns the array shape.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Auth.Credentials
  alias DmhAi.Tools.LookupCreds
  alias DmhAi.Repo

  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    user_id = "u-#{System.unique_integer([:positive])}"

    query!(Repo,
      "INSERT INTO users (id, email, password_hash, role) VALUES (?, ?, ?, ?)",
      [user_id, "ma-#{user_id}@test.local", "x", "user"])

    on_exit(fn ->
      query!(Repo, "DELETE FROM user_credentials WHERE user_id = ?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id = ?", [user_id])
    end)

    {:ok, user_id: user_id}
  end

  describe "schema — multi-account UNIQUE" do
    test "two rows for same target with different account co-exist", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "t1"}, account: "work@gmail.com")

      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "t2"}, account: "personal@gmail.com")

      rows = Credentials.lookup_all(c.user_id, "oauth:googleapis.com")
      accounts = rows |> Enum.map(& &1.account) |> Enum.sort()
      assert accounts == ["personal@gmail.com", "work@gmail.com"]
    end

    test "save/2 with same account upserts in place", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "old"}, account: "work@gmail.com")
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "new"}, account: "work@gmail.com")

      rows = Credentials.lookup_all(c.user_id, "oauth:googleapis.com")
      assert length(rows) == 1
      assert hd(rows).payload["access_token"] == "new"
    end
  end

  describe "lookup_all / lookup / delete API" do
    test "lookup/3 is account-scoped", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "work-tok"}, account: "work@gmail.com")

      assert %{account: "work@gmail.com", payload: %{"access_token" => "work-tok"}} =
               Credentials.lookup(c.user_id, "oauth:googleapis.com", "work@gmail.com")

      assert nil ==
               Credentials.lookup(c.user_id, "oauth:googleapis.com", "personal@gmail.com")
    end

    test "delete/3 removes one account leaving siblings intact", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "w"}, account: "work@gmail.com")
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "p"}, account: "personal@gmail.com")

      :ok = Credentials.delete(c.user_id, "oauth:googleapis.com", "work@gmail.com")

      remaining = Credentials.lookup_all(c.user_id, "oauth:googleapis.com")
      assert length(remaining) == 1
      assert hd(remaining).account == "personal@gmail.com"
    end

    test "delete_all/2 clears every account row for the target", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "w"}, account: "work@gmail.com")
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "p"}, account: "personal@gmail.com")

      :ok = Credentials.delete_all(c.user_id, "oauth:googleapis.com")

      assert Credentials.lookup_all(c.user_id, "oauth:googleapis.com") == []
    end
  end

  describe "lookup_creds tool — array shape" do
    test "returns credentials as an array even for a single account", c do
      :ok = Credentials.save(c.user_id, "api:weather", "api_key",
              %{"key" => "abc"}, account: "")

      assert {:ok, result} = LookupCreds.execute(%{"target" => "api:weather"}, %{user_id: c.user_id})
      assert result.found == true
      assert is_list(result.credentials)
      assert length(result.credentials) == 1
      [single] = result.credentials
      assert single.account == ""
      assert single.kind == "api_key"
    end

    test "returns one entry per account when multiple authorized", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "w"}, account: "work@gmail.com")
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "p"}, account: "personal@gmail.com")

      assert {:ok, result} =
               LookupCreds.execute(%{"target" => "oauth:googleapis.com"}, %{user_id: c.user_id})

      assert result.found == true
      assert length(result.credentials) == 2
      accounts = result.credentials |> Enum.map(& &1.account) |> Enum.sort()
      assert accounts == ["personal@gmail.com", "work@gmail.com"]
    end

    test "optional `account` arg filters to a single entry", c do
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "w"}, account: "work@gmail.com")
      :ok = Credentials.save(c.user_id, "oauth:googleapis.com", "oauth2_service",
              %{"access_token" => "p"}, account: "personal@gmail.com")

      assert {:ok, result} =
               LookupCreds.execute(
                 %{"target" => "oauth:googleapis.com", "account" => "work@gmail.com"},
                 %{user_id: c.user_id})

      assert length(result.credentials) == 1
      [only] = result.credentials
      assert only.account == "work@gmail.com"
      assert only.payload["access_token"] == "w"
    end

    test "missing target → empty credentials, found=false", c do
      assert {:ok, %{found: false, target: "oauth:nonexistent.test", credentials: []}} =
               LookupCreds.execute(%{"target" => "oauth:nonexistent.test"}, %{user_id: c.user_id})
    end
  end
end
