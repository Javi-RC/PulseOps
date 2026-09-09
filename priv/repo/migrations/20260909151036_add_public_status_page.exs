defmodule PulseOps.Repo.Migrations.AddPublicStatusPage do
  use Ecto.Migration

  # A public status page is served at /status/:slug with no authentication, so
  # both flags default to the safe answer and an organization has to opt in.
  #
  # Two flags rather than one, because they answer different questions.
  # `status_page_enabled` is "does this organization publish a page at all",
  # and it is off until somebody turns it on. `services.public` is "does this
  # particular service belong on it", and it defaults to true because turning
  # the page on is a statement about the things you are watching — a page that
  # starts empty and needs every service ticked reads as broken rather than as
  # careful. The URL of a service is never published either way.
  def change do
    alter table(:organizations) do
      add :status_page_enabled, :boolean, null: false, default: false
      add :status_page_headline, :string
    end

    alter table(:services) do
      add :public, :boolean, null: false, default: true
    end

    # The page is reached by slug, by strangers, and the lookup has to reject a
    # disabled organization without a second query.
    create index(:organizations, [:slug],
             where: "status_page_enabled",
             name: :organizations_public_status_page_index
           )
  end
end
