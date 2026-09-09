defmodule PulseOps.Repo.Migrations.CreateOrganizationInvitations do
  use Ecto.Migration

  # `add_member/3` could only add somebody who had already registered, which
  # made "invite people" — a thing the README claimed — impossible for the
  # common case: the person you want is not here yet.
  def change do
    create table(:organization_invitations) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)

      # citext, like users.email, so an invitation to Bob@example.com is the
      # same invitation as one to bob@example.com and cannot be duplicated by
      # changing the case.
      add :email, :citext, null: false
      add :role, :string, null: false

      # Only the hash, like every other token in this schema. The link is a
      # credential: whoever holds it can join the organization.
      add :hashed_token, :binary, null: false

      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_invitations, [:hashed_token])
    create index(:organization_invitations, [:organization_id])

    # One outstanding invitation per address per organization. Re-inviting
    # somebody replaces the pending one rather than leaving two live links.
    create unique_index(:organization_invitations, [:organization_id, :email],
             where: "accepted_at IS NULL",
             name: :organization_invitations_one_pending_per_email
           )
  end
end
