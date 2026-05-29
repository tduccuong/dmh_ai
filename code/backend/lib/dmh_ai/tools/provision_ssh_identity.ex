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
  same identity re-materialises the existing keypair (without
  touching the row) and then runs an `ssh BatchMode true` probe
  inside the sandbox: success ⇒ `status: "ready"`, failure ⇒
  `status: "needs_setup"` with the EXISTING public key so the
  user can re-install. The probe is the only source of truth —
  the tool does NOT cache verification state across calls.

  See `arch_wiki/dmh_ai/integrations.md` §SSH provisioning /
  §Verification.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Auth.Credentials
  alias DmhAi.Agent.Sandbox
  alias DmhAi.Permissions.SandboxUser

  @default_user_marker "_default_"

  @impl true
  def name, do: "provision_ssh_identity"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    """
    Provision a sandbox-owned SSH identity for `host` = `<remote_user>@<hostname>` (e.g. `root@example.com`) OR `<hostname>` alone (sandbox SSH config picks the default user). The harness keys the credential by `(host_part, remote_user)` and never asks for the user's private key.

    Call this when ssh fails on the remote (`Permission denied (publickey,password)`, host-key change, connection refused). The tool resolves to one of two outcomes:

    - `{status: "ready", private_key_path}` — the harness's key is installed AND currently authenticates against the remote. The tool just probed, so this is true RIGHT NOW. Issue the ssh against `private_key_path` and proceed.
    - `{status: "needs_setup", public_key, options, message}` — either a brand-new identity was minted, or the prior install is no longer accepted. Render the message + the public key + both install option snippets verbatim in the chat reply, then end the turn. The user runs one of the options (typically the `authorized_keys` snippet) and replies when done; your next call to this tool re-probes and returns `ready`.

    The probe is a single non-interactive `ssh … true` with a 5-second timeout that runs every time the credential already exists — no cached "verified" state. Treat the status field as the verdict: it reflects the remote at call time.
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
    user_id    = ctx[:user_id]    || ctx["user_id"]
    user_email = ctx[:user_email] || ctx["user_email"]
    user_role  = ctx[:user_role]  || ctx["user_role"]

    {remote_user, host_part} = split_user_and_host(host)

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "no user_id in context"}

      not is_binary(user_email) or user_email == "" ->
        {:error, "no user_email in context"}

      host_part == "" ->
        {:error, "host argument is empty after normalisation"}

      true ->
        user   = %{id: user_id, email: user_email, role: user_role || ""}
        target = "ssh:" <> host_part

        case Credentials.lookup(user_id, target, remote_user) do
          %{kind: "ssh_identity", payload: %{"private_key" => priv, "public_key" => pub}} ->
            existing_credential_outcome(user, remote_user, host_part, priv, pub)

          _ ->
            mint_new_identity(user, user_id, target, remote_user, host_part)
        end
    end
  end

  def execute(_, _), do: {:error, "host (string) is required"}

  # Lookup-hit branch: the credential row exists, so the keypair is
  # already minted. Materialise the file pair into the per-user
  # keystore (idempotent), then probe the remote with a 5-second
  # `ssh BatchMode true` from inside the sandbox. Probe-success ⇒
  # `ready`; probe-failure ⇒ `needs_setup` with the existing pubkey
  # so the user can (re-)install. The probe is the only source of
  # truth — there is no cached verified state. See
  # `arch_wiki/dmh_ai/integrations.md` §SSH provisioning /
  # §Verification.
  defp existing_credential_outcome(user, remote_user, host_part, priv, pub) do
    with {:ok, path} <- materialize(user, remote_user, host_part, priv, pub),
         {:ok, username} <- sandbox_username(user) do
      case Sandbox.probe_ssh(username, path, remote_user, host_part) do
        :ok ->
          {:ok, %{
            status:           "ready",
            host:             host_part,
            remote_user:      remote_user,
            private_key_path: path,
            public_key:       pub,
            hint:             ssh_hint(path, remote_user, host_part)
          }}

        {:error, probe_reason} ->
          {:ok, needs_setup_envelope(host_part, remote_user, path, pub, :reinstall, probe_reason)}
      end
    end
  end

  # Lookup-miss branch: no credential yet for this `(user, host,
  # remote_user)` tuple. Generate an ed25519 keypair, persist it,
  # materialise the file pair, and return `needs_setup` so the
  # model relays the install snippets to the user. No probe here —
  # the install obviously hasn't happened yet.
  defp mint_new_identity(user, user_id, target, remote_user, host_part) do
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

        with {:ok, path} <- materialize(user, remote_user, host_part, priv, pub) do
          {:ok, needs_setup_envelope(host_part, remote_user, path, pub, :first_install, nil)}
        end

      {:error, reason} ->
        {:error, "ssh-keygen failed: #{reason}"}
    end
  end

  # Build the `needs_setup` tool result. `phase` is `:first_install`
  # (brand-new identity) or `:reinstall` (existing credential, probe
  # failed) — the `message` field tells the model which situation
  # it's in so it can phrase the relay to the user accordingly.
  # `probe_error` is the ssh stderr from a failed probe (nil for
  # `:first_install`); we surface a short tail of it so the model
  # can distinguish "key never installed" from "host unreachable"
  # without re-probing.
  defp needs_setup_envelope(host_part, remote_user, path, pub, phase, probe_error) do
    user_host = format_user_host(remote_user, host_part)

    message =
      case phase do
        :first_install ->
          "A fresh identity was minted for this host. Render the `public_key` line and BOTH `options` snippets verbatim in the chat reply, then end the turn. The user will run one snippet on the remote and confirm; the next call to this tool re-probes and flips to `ready`."

        :reinstall ->
          "The identity exists locally but the remote does not currently accept it (probe failed; see `probe_error`). Render the `public_key` line and BOTH `options` snippets verbatim so the user can re-install; the next call re-probes."
      end

    base = %{
      status:           "needs_setup",
      host:             host_part,
      remote_user:      remote_user,
      private_key_path: path,
      public_key:       pub,
      options: %{
        password:        "If the remote allows password auth, request the password (use `request_input`) and install the public key in one shot:\n\n  sshpass -p <password> ssh-copy-id -i #{path}.pub -o StrictHostKeyChecking=accept-new #{user_host}\n\nSubsequent connects use `ssh -i #{path} #{user_host}` and never need the password again.",
        authorized_keys: "If the remote requires pubkey auth, ask the user to run on the remote, ONCE:\n\n  mkdir -p ~/.ssh && chmod 700 ~/.ssh\n  echo '#{pub}' >> ~/.ssh/authorized_keys\n  chmod 600 ~/.ssh/authorized_keys\n\nThen confirm; the next call to this tool will probe and return `ready`."
      },
      message: message
    }

    if probe_error, do: Map.put(base, :probe_error, probe_error), else: base
  end

  # The keystore files are owned by the per-user sandbox uid (mode
  # 0600), so the probe's `ssh` must run as that same uid inside the
  # container. Admin sessions resolve to the preset `master_username`
  # (consuming the same uid `uid_for` returns); non-admin sessions
  # resolve to the per-uid `dmh_ai-u<uid>` account allocated by
  # `ensure_provisioned`. Mirrors `RunScript.run_ctx_for/3`.
  defp sandbox_username(%{role: "admin"} = user) do
    with {:ok, _uid} <- SandboxUser.uid_for(user) do
      {:ok, SandboxUser.master_username()}
    end
  end

  defp sandbox_username(user) do
    with {:ok, uid} <- SandboxUser.uid_for(user) do
      {:ok, SandboxUser.username_for(uid)}
    end
  end

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

  # Write the keypair to disk using `Permissions.SandboxUser.write_keystore_file/4`,
  # which owns the path layout (`<email>/_keystore/.ssh/<slug>`),
  # mode (0600 priv, 0644 pub), and ownership (chowned to the
  # consuming sandbox uid so `run_script` can read the private key
  # when invoking ssh). Returns `{:ok, priv_path}` for the model.
  defp materialize(user, remote_user, host_part, priv, pub) do
    slug     = slug_for(remote_user, host_part)
    rel_priv = Path.join(".ssh", slug)
    rel_pub  = rel_priv <> ".pub"

    with {:ok, priv_path} <- SandboxUser.write_keystore_file(user, rel_priv, priv, 0o600),
         {:ok, _pub_path} <- SandboxUser.write_keystore_file(user, rel_pub,  pub,  0o644) do
      {:ok, priv_path}
    end
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
