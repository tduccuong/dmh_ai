defmodule Dmhai.Plugs.BlockScanners do
  @moduledoc "Drop common scanner/bot probe paths before they reach the router."
  import Plug.Conn

  # Path fragments that indicate a scanner probe
  @probes ~w(
    wp-admin wp-login wp-includes xmlrpc.php
    phpMyAdmin phpmyadmin admin.php config.php
    setup.php install.php shell.php cmd.php
    eval-stdin.php vendor/phpunit actuator
    .aws .ssh .env .git
  )

  def init(opts), do: opts

  def call(conn, _opts) do
    path = conn.request_path
    if dotfile?(path) or probe?(path) do
      conn |> send_resp(404, "") |> halt()
    else
      conn
    end
  end

  defp dotfile?(path), do: String.contains?(path, "/.")

  defp probe?(path), do: Enum.any?(@probes, &String.contains?(path, &1))
end
