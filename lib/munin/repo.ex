defmodule Munin.Repo do
  use Ecto.Repo,
    otp_app: :munin,
    adapter: Ecto.Adapters.Postgres
end
