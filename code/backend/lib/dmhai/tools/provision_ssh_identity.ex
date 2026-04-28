# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ProvisionSshIdentity do
  @moduledoc """
  Provision a sandbox-owned SSH client identity per `(user, host)` so
  the agent can authenticate to remote hosts without ever holding the
  user's personal private key.

  First call for a `(user, host)`:
    1. Generates an ed25519 keypair via `ssh-keygen`.
    2. Persists the **private** key in `user_credentials` at
       `target = "ssh:<host>"`, kind `ssh_identity`.
    3. Materialises the private key in the per-user keystore at
       `<keystore>/.ssh/<slug>` (chmod 0600). No filename suffix —
       the bare slug minimises the chance an LLM mis-copies the
       path when composing an `ssh -i …` invocation.
    4. Returns the **public** key plus two setup options for the
       user — password-based, or pubkey-only.

  Subsequent calls:
    1. Re-materialises the existing private key into the workspace
       (cheap; idempotent) so the model can ssh with `-i <path>`.
    2. Returns `status: "ready"` with the path.

  The user's personal SSH private key is never asked for, never
  stored. Only the harness-generated keypair lives in this user's
  credential vault. Compromise blast radius: the harness's identity
  on hosts that have its public key — equivalent to a standard CI
  runner key.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Auth.Credentials

  @impl true
  def name, do: "provision_ssh_identity"

  @impl true
  def description do
    """
    Provision a sandbox-owned SSH identity for a remote host (`host` = hostname or `user@host`). First call returns `{status: "needs_setup", public_key, ...}`. Subsequent calls return `{status: "ready", private_key_path}` — use `ssh -i <path> <host>`.
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
            description: "Remote hostname or `user@host`. Used as the credential target key, so be consistent across calls for the same destination."
          }
        },
        required: ["host"]
      }
    }
  end

  @impl true
  def execute(%{"host" => host}, ctx) when is_binary(host) and host != "" do
    user_id  = ctx[:user_id] || ctx["user_id"]
    keystore = Map.get(ctx, :keystore_dir)

    canonical = canonicalize_host(host)

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "no user_id in context"}

      not is_binary(keystore) or keystore == "" ->
        {:error, "no keystore_dir in context"}

      canonical == "" ->
        {:error, "host argument is empty after normalisation"}

      true ->
        target = "ssh:" <> canonical

        case Credentials.lookup(user_id, target) do
          %{kind: "ssh_identity", payload: %{"private_key" => priv, "public_key" => pub}} ->
            path = materialize(keystore, canonical, priv, pub)

            {:ok, %{
              status:           "ready",
              host:             canonical,
              private_key_path: path,
              public_key:       pub,
              hint:             "Use `ssh -i #{path} #{canonical}` (or `<remote_user>@<host>` if the host has no user prefix)."
            }}

          _ ->
            case generate_keypair(canonical) do
              {:ok, priv, pub} ->
                Credentials.save(
                  user_id, target, "ssh_identity",
                  %{
                    "private_key" => priv,
                    "public_key"  => pub,
                    "host"        => canonical
                  },
                  notes: "DMH-AI sandbox identity for SSH to #{canonical}"
                )

                path = materialize(keystore, canonical, priv, pub)

                {:ok, %{
                  status:           "needs_setup",
                  host:             canonical,
                  private_key_path: path,
                  public_key:       pub,
                  options: %{
                    password:        "If the remote server allows password authentication, ask the user for the password (use `request_input`). Once received, install this identity's public key on the remote in one shot, e.g.:\n\n  sshpass -p <password> ssh-copy-id -i #{path}.pub -o StrictHostKeyChecking=accept-new #{canonical}\n\nThen subsequent connects use `ssh -i #{path} #{canonical}` and never need the password again.",
                    authorized_keys: "If the server only allows pubkey auth (no password login), relay this public key to the user and ask them to run, on the remote, ONCE:\n\n  mkdir -p ~/.ssh && chmod 700 ~/.ssh\n  echo '#{pub}' >> ~/.ssh/authorized_keys\n  chmod 600 ~/.ssh/authorized_keys\n\nWhen the user confirms it's done, retry `ssh -i #{path} #{canonical}` to verify connectivity."
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

  # ── private ───────────────────────────────────────────────────────────

  defp canonicalize_host(host) do
    host
    |> String.trim()
    |> String.downcase()
  end

  defp generate_keypair(canonical) do
    tmp = System.tmp_dir!() |> Path.join("dmhai_keypair_" <> mint_token(8))

    case System.cmd("ssh-keygen",
           ["-t", "ed25519", "-f", tmp, "-N", "", "-q",
            "-C", "dmhai-sandbox@" <> canonical],
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

  defp materialize(keystore, canonical, priv, pub) do
    ssh_dir = Path.join(keystore, ".ssh")
    File.mkdir_p!(ssh_dir)

    slug = String.replace(canonical, ~r/[^a-z0-9._-]/, "_")
    path = Path.join(ssh_dir, slug)

    File.write!(path, priv)
    File.chmod!(path, 0o600)

    File.write!(path <> ".pub", pub)
    File.chmod!(path <> ".pub", 0o644)

    path
  end

  defp mint_token(byte_count) do
    :crypto.strong_rand_bytes(byte_count) |> Base.url_encode64(padding: false)
  end
end
