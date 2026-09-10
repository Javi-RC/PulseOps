defmodule PulseOps.Repo.Migrations.AddTlsExpiryToServices do
  use Ecto.Migration

  # An expired certificate takes a service down as surely as a crashed process,
  # and it is the one outage that announces itself weeks in advance to anybody
  # who looks. Nothing was looking.
  def change do
    alter table(:services) do
      add :tls_expires_at, :utc_datetime
      add :tls_checked_at, :utc_datetime
      add :tls_error, :string

      # Which expiry was warned about, rather than merely whether a warning was
      # sent. Renewing the certificate moves the expiry, which is what makes the
      # next warning legitimate — a boolean would either warn daily or go quiet
      # for ever after the first one.
      add :tls_warned_for, :utc_datetime
    end

    # The daily job asks "which https services are due a look", and the warning
    # asks "which are expiring soon"; both scan on this column.
    create index(:services, [:tls_expires_at])
  end
end
