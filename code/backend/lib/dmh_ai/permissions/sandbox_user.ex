# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Permissions.SandboxUser do
  @moduledoc """
  Per-user OS account + filesystem provisioning inside the assistant
  sandbox container. See specs/permissions.md.

  Lazy and idempotent: master calls `ensure_provisioned/1` before the
  first `docker exec` for a given user. The function

    1. Allocates a Linux UID for this user if `users.unix_uid` is NULL.
       UIDs are sequential, starting at @uid_base, stored in the DB.
       The DB is the source of truth; sandbox's `/etc/passwd` is
       reconstructed lazily from it.
    2. `useradd`s the corresponding account inside the sandbox
       container if it doesn't exist there yet (e.g. fresh container
       after a restart).
    3. Creates and chowns the user's two host-side directories
       (`user_assets/<email>/`, `user_workspaces/<email>/`) so the
       per-user OS account can read its assets and read/write its
       workspace; cross-user access is blocked at the kernel layer
       by mode 0700.

  Re-running on an already-provisioned user is a no-op at every step.

  All shell calls funnel through `DmhAi.Permissions.SandboxUser.docker/2`
  with a hard timeout — a stuck docker daemon surfaces as `:timeout`
  rather than freezing the chain.
  """

  require Logger

  alias DmhAi.Agent.Sandbox
  alias DmhAi.Constants
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # First Linux UID handed out to a regular user. Master service identity
  # is `dmh_ai-master-u` (UID 10000). Per-user accounts allocate from
  # 10001 upward. Spec §Per-user account provisioning.
  @uid_base 10_000
  @uid_first_user 10_001

  # Hard timeout per docker invocation — stuck daemon shouldn't wedge a
  # provisioning attempt.
  @docker_timeout_ms 5_000

  @typedoc "User row excerpt that's enough to provision."
  @type user_ref :: %{required(:id) => String.t(), required(:email) => String.t()}

  @doc """
  Provision (or no-op) the sandbox-side state for `user`. Returns
  `{:ok, uid}` on success, `{:error, reason}` if any step failed. The
  caller — typically `run_script` — uses `uid` to build the
  `docker exec -u dmh_ai-u<uid> -w /work/<email>/<session>/ …`
  command.
  """
  @spec ensure_provisioned(user_ref()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def ensure_provisioned(%{id: user_id, email: email}) when is_binary(user_id) and is_binary(email) do
    with {:ok, uid}      <- ensure_uid(user_id),
         :ok             <- ensure_os_user(uid),
         :ok             <- ensure_host_dirs(email, uid),
         :ok             <- ensure_sandbox_workspace_perms(email, uid) do
      {:ok, uid}
    end
  end

  @doc "Username inside the sandbox for a given UID."
  @spec username_for(non_neg_integer()) :: String.t()
  def username_for(uid) when is_integer(uid), do: "dmh_ai-u#{uid}"

  @doc "Master's exec identity inside the sandbox."
  @spec master_username() :: String.t()
  def master_username, do: "dmh_ai-master-u"

  @doc "Master's UID inside the sandbox (admin pass-through in iptables)."
  @spec master_uid() :: non_neg_integer()
  def master_uid, do: @uid_base

  # ─── Private ──────────────────────────────────────────────────────────────

  # Allocate `users.unix_uid` if NULL. Sequential, starting at
  # @uid_first_user. Two concurrent provisions for different users
  # serialize via the (max(unix_uid)+1, INSERT) sequence — collisions
  # are caught by the partial unique index from db/init.ex and we
  # retry once.
  defp ensure_uid(user_id) do
    case fetch_uid(user_id) do
      {:ok, uid} when is_integer(uid) ->
        {:ok, uid}

      {:ok, nil} ->
        allocate_uid(user_id)

      {:error, reason} ->
        {:error, "failed to read users.unix_uid: #{inspect(reason)}"}
    end
  end

  defp fetch_uid(user_id) do
    case query!(Repo, "SELECT unix_uid FROM users WHERE id = ?", [user_id]) do
      %{rows: [[uid]]} -> {:ok, uid}
      %{rows: []}      -> {:error, :user_not_found}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp allocate_uid(user_id) do
    next_uid =
      case query!(Repo, "SELECT COALESCE(MAX(unix_uid), ?) + 1 FROM users WHERE unix_uid IS NOT NULL", [@uid_first_user - 1]) do
        %{rows: [[n]]} when is_integer(n) -> n
        _ -> @uid_first_user
      end

    try do
      query!(Repo, "UPDATE users SET unix_uid = ? WHERE id = ? AND unix_uid IS NULL",
             [next_uid, user_id])

      # Confirm the write — the predicate `unix_uid IS NULL` makes
      # this race-safe across concurrent allocate calls for the
      # *same* user. Different-user concurrency hits the partial
      # unique index instead — we'd see an exception above and
      # retry once with a fresh max.
      case query!(Repo, "SELECT unix_uid FROM users WHERE id = ?", [user_id]) do
        %{rows: [[uid]]} when is_integer(uid) -> {:ok, uid}
        _ -> {:error, "uid not persisted"}
      end
    rescue
      _ ->
        # Most likely cause: partial unique index conflict from a
        # concurrent allocation that just landed @next_uid. Re-read
        # current uid; if still NULL, the original caller raced and
        # we retry once with a fresh max.
        case fetch_uid(user_id) do
          {:ok, uid} when is_integer(uid) -> {:ok, uid}
          _ -> retry_allocate_uid(user_id)
        end
    end
  end

  defp retry_allocate_uid(user_id) do
    next_uid =
      case query!(Repo, "SELECT COALESCE(MAX(unix_uid), ?) + 1 FROM users WHERE unix_uid IS NOT NULL", [@uid_first_user - 1]) do
        %{rows: [[n]]} when is_integer(n) -> n
        _ -> @uid_first_user
      end

    query!(Repo, "UPDATE users SET unix_uid = ? WHERE id = ? AND unix_uid IS NULL", [next_uid, user_id])

    case fetch_uid(user_id) do
      {:ok, uid} when is_integer(uid) -> {:ok, uid}
      _ -> {:error, "uid allocation retry failed"}
    end
  end

  # `useradd` inside the sandbox if `dmh_ai-u<uid>` doesn't exist yet.
  # Idempotent: existing entry → exit code 9 from useradd, swallowed
  # via the `id` precheck. Sandbox container restart wipes
  # `/etc/passwd`; this re-creates it lazily on next provision call.
  defp ensure_os_user(uid) do
    name = username_for(uid)

    cmd =
      """
      if id #{name} >/dev/null 2>&1; then
        :
      else
        useradd -u #{uid} -M -s /bin/sh #{name}
      fi
      """

    case docker(["exec", Sandbox.container_name(), "sh", "-c", cmd], @docker_timeout_ms) do
      {:ok, _, 0} -> :ok
      {:ok, out, code} -> {:error, "useradd #{name} failed (exit #{code}): #{String.slice(out, 0, 200)}"}
      :timeout -> {:error, "useradd #{name} timed out — docker daemon stuck?"}
      {:error, reason} -> {:error, "useradd #{name} failed: #{inspect(reason)}"}
    end
  end

  # Create the user's per-tree host directories with the right
  # ownership and permissions. Master runs as root (see spec
  # §Master container changes), so `File.chmod/2` and the lower-
  # level `:os.cmd/1` can chown to non-master UIDs.
  defp ensure_host_dirs(email, uid) do
    assets   = Path.join(Constants.assets_dir(),     to_string(email))
    work     = Path.join(Constants.workspaces_dir(), to_string(email))

    File.mkdir_p!(assets)
    File.mkdir_p!(work)

    # chown via `:os.cmd/1` — Elixir doesn't expose a direct chown.
    # Quote the email defensively for shell.
    safe = email |> to_string() |> String.replace("'", "'\\''")
    chown_cmd = "chown #{uid}:#{uid} '#{Constants.assets_dir()}/#{safe}' '#{Constants.workspaces_dir()}/#{safe}'"
    _ = :os.cmd(String.to_charlist(chown_cmd))

    File.chmod!(assets, 0o700)
    File.chmod!(work,   0o700)
    :ok
  rescue
    e -> {:error, "host dir provisioning failed: #{Exception.message(e)}"}
  end

  # The host-side mkdir made `<workspaces>/<email>/` owned by the
  # right user, but we may need finer perms on contents (sub-dirs
  # auto-created by tools). Sandbox runs as root and sees the same
  # tree at `/work/<email>/`, so a `chown -R` from inside the
  # container is a clean way to repair perms after a session-dir
  # was created earlier under a different uid.
  defp ensure_sandbox_workspace_perms(email, uid) do
    safe = email |> to_string() |> String.replace("'", "'\\''")
    cmd = "chown -R #{uid}:#{uid} '/work/#{safe}' 2>/dev/null; chmod 0700 '/work/#{safe}'"

    case docker(["exec", Sandbox.container_name(), "sh", "-c", cmd], @docker_timeout_ms) do
      {:ok, _, _} -> :ok
      :timeout -> {:error, "chown -R inside sandbox timed out"}
      {:error, reason} -> {:error, "chown -R inside sandbox failed: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec docker([String.t()], non_neg_integer()) ::
          {:ok, String.t(), non_neg_integer()} | :timeout | {:error, term()}
  def docker(args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {:ok, output, code}
      nil -> :timeout
      {:exit, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
