# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.SysLog do
  @moduledoc """
  Serialised writer for /data/system_logs/system.log.

  All writes go through a single GenServer so rotation is race-free.
  When the log file reaches ~20 MB it is gzip-compressed with a timestamp
  suffix and a fresh empty file is started.
  """

  use GenServer
  require Logger

  @log_file Application.compile_env(:dmhai, :syslog_path, "/data/system_logs/system.log")
  @max_bytes 20 * 1024 * 1024

  # ─── Public API ────────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec log(String.t()) :: :ok
  def log(msg) when is_binary(msg) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:log, msg})
    end
    :ok
  end

  # ─── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    File.mkdir_p!(Path.dirname(@log_file))
    {:ok, nil}
  end

  @impl true
  def handle_cast({:log, msg}, state) do
    ts = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)
    line = "[#{ts}] #{msg}\n"
    File.write!(@log_file, line, [:append])
    maybe_rotate()
    {:noreply, state}
  end

  # ─── Rotation ──────────────────────────────────────────────────────────────

  defp maybe_rotate do
    case File.stat(@log_file) do
      {:ok, %{size: size}} when size >= @max_bytes ->
        rotate()

      _ ->
        :ok
    end
  end

  defp rotate do
    ts =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.to_string()
      |> String.slice(0, 19)
      |> String.replace(" ", "_")
      |> String.replace(":", "-")

    dir     = Path.dirname(@log_file)
    archive = Path.join(dir, "system.#{ts}.log.gz")

    with {:ok, content} <- File.read(@log_file),
         compressed      = :zlib.gzip(content),
         :ok            <- File.write(archive, compressed),
         :ok            <- File.write(@log_file, "") do
      Logger.info("[SysLog] rotated → #{archive}")
    else
      err -> Logger.error("[SysLog] rotation failed: #{inspect(err)}")
    end
  end
end
