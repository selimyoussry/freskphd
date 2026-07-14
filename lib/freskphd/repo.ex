defmodule Freskphd.Repo do
  use Ecto.Repo,
    otp_app: :freskphd,
    adapter: Ecto.Adapters.SQLite3
end
