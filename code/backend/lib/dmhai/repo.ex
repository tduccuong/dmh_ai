defmodule Dmhai.Repo do
  use Ecto.Repo,
    otp_app: :dmhai,
    adapter: Ecto.Adapters.SQLite3
end
