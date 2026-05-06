# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ProvisionSshIdentity do
  @moduledoc """
  Provision a sandbox-owned SSH client identity per
  `(user_id, host_part, remote_user)` so the agent can authenticate
  to remote hosts without ever holding the user's personal private
  key.

  The model passes `host` as either:

    * `<remote_user>@<host_part>` — e.g. `cuong@example.com`,
      `root@203.0.113.42`. Splits on the first `@`.
    * `<host_part>` alone — defaults the remote user to `""` (sandbox
      SSH config picks the default user).

  `<host_part>` is whatever the model passed (domain or IP); the tool
  does **not** perform DNS resolution and does not attempt to
  cross-reference. Storing by domain matches how humans address
  machines and survives DNS-record changes (which usually mean the
  same machine got a new lease, not that the name now points
  elsewhere).

  Storage:

      target  = "ssh:<host_part>"   (lowercased + trimmed; no <user>@ prefix)
      account = "<remote_user>"     (may be ""; UNIQUE on (user_id, target, account))
      kind    = "ssh_identity"
      payload = %{
        "host":        "<host_part>",
        "remote_user": "<remote_user>",
        "private_key": "<PEM>",
        "public_key":  "<openssh-fmt>"
      }

  Two distinct remote users on the same host become two distinct rows
  (e.g. `cuong@example.com` and `root@example.com`). Materialised
  files in the keystore are slugged per-account
  (`<remote_user_or_'_default_'>_<host_safe>`), so the file pairs
  don't collide.

  Idempotent on the `(target, account)` key — re-provisioning the
  same identity re-materialises the existing keypair and returns
  `status: "ready"`.

  See `arch_wiki/dmh_ai/integrations.md` §SSH provisioning.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Auth.Credentials

  @default_user_marker "_default_"

  @impl true
  def name, do: "provision_ssh_identity"

  @impl true
  def description do
    """
    Provision a sandbox-owned SSH identity for `host` = `<remote_user>@<hostname>` (e.g. `root@example.com`) OR `<hostname>` alone (defaults to sandbox SSH config user). The harness keys the credential by `(host_part, remote_user)`, so different users on the same host are independent identities. Pass the hostname or IP exactly the way the user does; no DNS resolution. First call returns `{status: "needs_setup", public_key, private_key_path, ...}`. Subsequent calls return `{status: "ready", private_key_path}` — use `ssh -i <path> <remote_user>@<host_part>`.
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          host: %{
            type: "string",
            description: "`<remote_user>@<hostname>` (e.g. `root@example.com`) or just `<hostname>`. Hostname can be a domain or an IP — pass it as the user does."
          }
        },
        required: ["host"]
      }
    }
  end

  @impl true
  def execute(%{"host" => host}, ctx) when is_binary(host) and host != "" do
    user_id  = ctx[:user_id] || ctx["user_id"]
    keystore = Map.fetch!(ctx, :keystore_dir)

    {remote_user, host_part} = split_user_and_host(host)

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "no user_id in context"}

      host_part == "" ->
        {:error, "host argument is empty after normalisation"}

      true ->
        target = "ssh:" <> host_part

        case Credentials.lookup(user_id, target, remote_user) do
          %{kind: "ssh_identity", payload: %{"private_key" => priv, "public_key" => pub}} ->
            path = materialize(keystore, remote_user, host_part, priv, pub)

            {:ok, %{
              status:           "ready",
              host:             host_part,
              remote_user:      remote_user,
              private_key_path: path,
              public_key:       pub,
              hint:             ssh_hint(path, remote_user, host_part)
            }}

          _ ->
            case generate_keypair(remote_user, host_part) do
              {:ok, priv, pub} ->
                Credentials.save(
                  user_id, target, "ssh_identity",
                  %{
                    "host"        => host_part,
                    "remote_user" => remote_user,
                    "private_key" => priv,
                    "public_key"  => pub
                  },
                  account: remote_user,
                  notes:   "DMH-AI sandbox identity for SSH to " <>
                             format_user_host(remote_user, host_part)
                )

                path = materialize(keystore, remote_user, host_part, priv, pub)
                user_host = format_user_host(remote_user, host_part)

                {:ok, %{
                  status:           "needs_setup",
                  host:             host_part,
                  remote_user:      remote_user,
                  private_key_path: path,
                  public_key:       pub,
                  options: %{
                    password:        "If the remote server allows password authentication, ask the user for the password (use `request_input`). Once received, install this identity's public key on the remote in one shot, e.g.:\n\n  sshpass -p <password> ssh-copy-id -i #{path}.pub -o StrictHostKeyChecking=accept-new #{user_host}\n\nThen subsequent connects use `ssh -i #{path} #{user_host}` and never need the password again.",
                    authorized_keys: "If the server only allows pubkey auth (no password login), relay this public key to the user and ask them to run, on the remote, ONCE:\n\n  mkdir -p ~/.ssh && chmod 700 ~/.ssh\n  echo '#{pub}' >> ~/.ssh/authorized_keys\n  chmod 600 ~/.ssh/authorized_keys\n\nWhen the user confirms it's done, retry `ssh -i #{path} #{user_host}` to verify connectivity."
                  },
                  message: "First-time identity provisioned. Relay the public key and the two setup options to the user as a clear bullet list, then wait for them to either (a) provide a password (use request_input) or (b) confirm they've installed the public key on the remote. Do NOT ask for their personal private key."
                }}

              {:error, reason} ->
                {:error, "ssh-keygen failed: #{reason}"}
            end
        end
    end
  end

  def execute(_, _), do: {:error, "host (string) is required"}

  # ── public helpers ────────────────────────────────────────────────────

  @doc """
  Split a `host` argument into `{remote_user, host_part}`. Accepts
  `user@host` (splits on the first `@`) or `host` alone (returns
  `{"", host}`). Both halves are trimmed; `host_part` is lowercased.
  """
  @spec split_user_and_host(String.t()) :: {String.t(), String.t()}
  def split_user_and_host(input) when is_binary(input) do
    case String.split(input, "@", parts: 2) do
      [user, host] ->
        {String.trim(user), host |> String.trim() |> String.downcase()}

      [host] ->
        {"", host |> String.trim() |> String.downcase()}
    end
  end

  @doc """
  Filename slug for the materialised keypair of `(remote_user, host_part)`.
  Empty `remote_user` falls back to the literal marker `_default_`.
  Non-`[a-z0-9._-]` chars in the host (e.g. IPv6 colons) become
  underscores.
  """
  @spec slug_for(String.t(), String.t()) :: String.t()
  def slug_for(remote_user, host_part) do
    user_part = if remote_user == "", do: @default_user_marker, else: remote_user
    sanitise_user(user_part) <> "_" <> sanitise_host(host_part)
  end

  @doc """
  Absolute paths the tool wrote when materialising the keypair for
  `(remote_user, host_part)` — `{private_key_path, public_key_path}`.
  Public so `DeleteCreds` can clean the files on credential delete.
  """
  @spec materialised_paths(String.t(), String.t(), String.t()) ::
          {String.t(), String.t()}
  def materialised_paths(keystore_dir, remote_user, host_part)
      when is_binary(keystore_dir) and is_binary(remote_user) and is_binary(host_part) do
    path = Path.join([keystore_dir, ".ssh", slug_for(remote_user, host_part)])
    {path, path <> ".pub"}
  end

  # ── private ───────────────────────────────────────────────────────────

  defp format_user_host("", host_part), do: host_part
  defp format_user_host(user, host_part), do: user <> "@" <> host_part

  defp ssh_hint(path, "", host_part),
    do: "Use `ssh -i #{path} #{host_part}` (sandbox SSH config picks the default user)."

  defp ssh_hint(path, remote_user, host_part),
    do: "Use `ssh -i #{path} #{remote_user}@#{host_part}`."

  defp generate_keypair(remote_user, host_part) do
    tmp = System.tmp_dir!() |> Path.join("dmh_ai_keypair_" <> mint_token(8))
    comment = "dmh_ai-sandbox@" <> format_user_host(remote_user, host_part)

    case System.cmd("ssh-keygen",
           ["-t", "ed25519", "-f", tmp, "-N", "", "-q", "-C", comment],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        priv = File.read!(tmp)
        pub  = File.read!(tmp <> ".pub") |> String.trim()
        _ = File.rm(tmp)
        _ = File.rm(tmp <> ".pub")
        {:ok, priv, pub}

      {output, code} ->
        _ = File.rm(tmp)
        _ = File.rm(tmp <> ".pub")
        {:error, "exit #{code}: #{String.slice(output, 0, 400)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp materialize(keystore, remote_user, host_part, priv, pub) do
    File.mkdir_p!(Path.join(keystore, ".ssh"))
    {priv_path, pub_path} = materialised_paths(keystore, remote_user, host_part)

    File.write!(priv_path, priv)
    File.chmod!(priv_path, 0o600)

    File.write!(pub_path, pub)
    File.chmod!(pub_path, 0o644)

    priv_path
  end

  defp sanitise_user(user) do
    String.replace(user, ~r/[^a-z0-9._-]/i, "_")
  end

  defp sanitise_host(host) do
    String.replace(host, ~r/[^a-z0-9._-]/, "_")
  end

  defp mint_token(byte_count) do
    :crypto.strong_rand_bytes(byte_count) |> Base.url_encode64(padding: false)
  end
end
