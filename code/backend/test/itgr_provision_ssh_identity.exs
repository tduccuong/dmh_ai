# Multi-account SSH provisioning. Locks the contract that
# `(user_id, target, account)` is `(user_id, "ssh:<host_part>", remote_user)`,
# the materialised file slug is `<remote_user|_default_>_<host_part>`,
# and re-provisioning the same identity is idempotent on the
# (target, account) pair.

defmodule Itgr.ProvisionSshIdentity do
  use ExUnit.Case, async: false

  alias DmhAi.Auth.Credentials
  alias DmhAi.Tools.ProvisionSshIdentity
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  setup do
    user_id = uid()
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "ssh_#{user_id}@itgr.local", "user", now])

    keystore = Path.join(System.tmp_dir!(), "dmh_ai_ks_" <> uid())
    File.mkdir_p!(Path.join(keystore, ".ssh"))
    on_exit(fn -> File.rm_rf!(keystore) end)

    {:ok, user_id: user_id, keystore: keystore}
  end

  defp ctx_for(user_id, keystore),
    do: %{user_id: user_id, keystore_dir: keystore}

  describe "split_user_and_host/1" do
    test "splits on the first @ and lowercases the host" do
      assert {"cuong", "example.com"} = ProvisionSshIdentity.split_user_and_host("cuong@Example.com")
      assert {"root", "203.0.113.42"} = ProvisionSshIdentity.split_user_and_host("root@203.0.113.42")
    end

    test "no @: empty remote_user, host lowercased" do
      assert {"", "example.com"} = ProvisionSshIdentity.split_user_and_host("Example.com")
    end

    test "trims surrounding whitespace on both halves" do
      assert {"cuong", "example.com"} =
               ProvisionSshIdentity.split_user_and_host("  cuong @ example.com  ")
    end
  end

  describe "slug_for/2" do
    test "default user marker when remote_user is empty" do
      assert ProvisionSshIdentity.slug_for("", "example.com") == "_default__example.com"
    end

    test "concatenates user + host with underscore" do
      assert ProvisionSshIdentity.slug_for("cuong", "example.com") == "cuong_example.com"
      assert ProvisionSshIdentity.slug_for("root", "203.0.113.42") == "root_203.0.113.42"
    end

    test "ipv6 colons sanitised to underscores in host segment" do
      assert ProvisionSshIdentity.slug_for("root", "2001:db8::1") == "root_2001_db8__1"
    end
  end

  describe "first-time provisioning (needs_setup)" do
    test "with user@host: stores account=user, target=ssh:<host>, slug per account",
         %{user_id: user_id, keystore: keystore} do
      assert {:ok, result} =
               ProvisionSshIdentity.execute(%{"host" => "cuong@Example.test"},
                 ctx_for(user_id, keystore))

      assert result.status      == "needs_setup"
      assert result.host        == "example.test"
      assert result.remote_user == "cuong"

      # Credential row keyed by (target, account)
      assert %{kind: "ssh_identity", account: "cuong", payload: payload} =
               Credentials.lookup(user_id, "ssh:example.test", "cuong")

      assert payload["host"]        == "example.test"
      assert payload["remote_user"] == "cuong"
      assert payload["public_key"]  =~ "ssh-ed25519"

      # Materialised file pair lives at the per-account slug
      {priv_path, pub_path} =
        ProvisionSshIdentity.materialised_paths(keystore, "cuong", "example.test")

      assert File.exists?(priv_path)
      assert File.exists?(pub_path)
      assert File.stat!(priv_path).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(pub_path).mode  |> Bitwise.band(0o777) == 0o644

      # Setup-options text addresses the user@host the model passed
      assert result.options.password        =~ "cuong@example.test"
      assert result.options.authorized_keys =~ "cuong@example.test"
    end

    test "with bare host: account=\"\", default-user slug",
         %{user_id: user_id, keystore: keystore} do
      assert {:ok, result} =
               ProvisionSshIdentity.execute(%{"host" => "Example.test"},
                 ctx_for(user_id, keystore))

      assert result.host        == "example.test"
      assert result.remote_user == ""

      assert %{kind: "ssh_identity", account: ""} =
               Credentials.lookup(user_id, "ssh:example.test", "")

      {priv_path, _} =
        ProvisionSshIdentity.materialised_paths(keystore, "", "example.test")

      assert File.exists?(priv_path)
      # Setup-options text omits the user prefix when none was given —
      # it addresses the bare hostname.
      assert result.options.password =~ " example.test"
      refute result.options.password =~ "@example.test"
    end

    test "host is stored verbatim (no DNS resolution)",
         %{user_id: user_id, keystore: keystore} do
      # Pass an IP literal — should land at ssh:<ip>, not at any
      # reverse-resolved name
      assert {:ok, _} =
               ProvisionSshIdentity.execute(%{"host" => "deploy@203.0.113.42"},
                 ctx_for(user_id, keystore))

      assert %{} = Credentials.lookup(user_id, "ssh:203.0.113.42", "deploy")
      # No accidental row at any other target
      assert Credentials.lookup_all(user_id, "ssh:203.0.113.42") |> length() == 1
    end
  end

  describe "idempotent re-provisioning (status: ready)" do
    test "second call returns ready without modifying the row",
         %{user_id: user_id, keystore: keystore} do
      assert {:ok, %{status: "needs_setup"}} =
               ProvisionSshIdentity.execute(%{"host" => "cuong@example.test"},
                 ctx_for(user_id, keystore))

      first = Credentials.lookup(user_id, "ssh:example.test", "cuong")
      first_priv = first.payload["private_key"]

      assert {:ok, %{status: "ready"} = result} =
               ProvisionSshIdentity.execute(%{"host" => "cuong@example.test"},
                 ctx_for(user_id, keystore))

      assert result.host        == "example.test"
      assert result.remote_user == "cuong"

      # Row is unchanged: same keypair, same account
      after_row = Credentials.lookup(user_id, "ssh:example.test", "cuong")
      assert after_row.payload["private_key"] == first_priv
    end
  end

  describe "multi-account on the same host" do
    test "two distinct remote_users on the same host produce two distinct rows + file pairs",
         %{user_id: user_id, keystore: keystore} do
      assert {:ok, _} =
               ProvisionSshIdentity.execute(%{"host" => "cuong@example.test"},
                 ctx_for(user_id, keystore))

      assert {:ok, _} =
               ProvisionSshIdentity.execute(%{"host" => "root@example.test"},
                 ctx_for(user_id, keystore))

      rows = Credentials.lookup_all(user_id, "ssh:example.test")
      accounts = rows |> Enum.map(& &1.account) |> Enum.sort()
      assert accounts == ["cuong", "root"]

      {priv_cuong, _} =
        ProvisionSshIdentity.materialised_paths(keystore, "cuong", "example.test")

      {priv_root, _} =
        ProvisionSshIdentity.materialised_paths(keystore, "root", "example.test")

      assert File.exists?(priv_cuong)
      assert File.exists?(priv_root)
      refute File.read!(priv_cuong) == File.read!(priv_root),
             "distinct accounts must get distinct keypairs"
    end

    test "default-user-and-named-user on the same host coexist",
         %{user_id: user_id, keystore: keystore} do
      {:ok, _} = ProvisionSshIdentity.execute(%{"host" => "example.test"},
                   ctx_for(user_id, keystore))

      {:ok, _} = ProvisionSshIdentity.execute(%{"host" => "cuong@example.test"},
                   ctx_for(user_id, keystore))

      rows = Credentials.lookup_all(user_id, "ssh:example.test")
      accounts = rows |> Enum.map(& &1.account) |> Enum.sort()
      assert accounts == ["", "cuong"]
    end
  end

  describe "input guards" do
    test "missing user_id → {:error, _}", %{keystore: keystore} do
      assert {:error, _} =
               ProvisionSshIdentity.execute(%{"host" => "x@y"}, %{keystore_dir: keystore})
    end

    test "missing keystore_dir in ctx raises (caller bug, not user error)",
         %{user_id: user_id} do
      assert_raise KeyError, fn ->
        ProvisionSshIdentity.execute(%{"host" => "x@y"}, %{user_id: user_id})
      end
    end

    test "empty host string → {:error, _}", %{user_id: user_id, keystore: keystore} do
      assert {:error, _} =
               ProvisionSshIdentity.execute(%{"host" => ""}, ctx_for(user_id, keystore))

      assert {:error, _} =
               ProvisionSshIdentity.execute(%{"host" => "   "}, ctx_for(user_id, keystore))
    end
  end
end
