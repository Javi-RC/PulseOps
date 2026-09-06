defmodule PulseOps.Repo do
  use Ecto.Repo,
    otp_app: :pulse_ops,
    adapter: Ecto.Adapters.Postgres
end
