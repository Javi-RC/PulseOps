defmodule PulseOps.Notifications.NotifierTest do
  use PulseOps.DataCase, async: true

  import PulseOps.OrganizationsFixtures

  alias PulseOps.Notifications.Notifier

  describe "changeset/3" do
    test "requires a name and a type" do
      scope = organization_scope_fixture()

      changeset = Notifier.changeset(%Notifier{}, %{}, scope)

      assert %{name: ["can't be blank"], type: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "rejects an unknown type" do
      scope = organization_scope_fixture()

      changeset = Notifier.changeset(%Notifier{}, %{name: "Pager", type: :siren}, scope)

      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "a webhook requires an http(s) URL" do
      scope = organization_scope_fixture()

      changeset =
        Notifier.changeset(%Notifier{}, %{name: "Pager", type: :webhook, url: "not-a-url"}, scope)

      assert %{url: ["must be an http(s) URL"]} = errors_on(changeset)
    end

    test "an email requires a valid recipient" do
      scope = organization_scope_fixture()

      changeset =
        Notifier.changeset(%Notifier{}, %{name: "Pager", type: :email, recipient: "nope"}, scope)

      assert %{recipient: ["must be a valid email address"]} = errors_on(changeset)
    end

    test "an email does not need a URL and a webhook does not need a recipient" do
      scope = organization_scope_fixture()

      assert %Ecto.Changeset{valid?: true} =
               Notifier.changeset(
                 %Notifier{},
                 %{
                   name: "Mail",
                   type: :email,
                   recipient: "oncall@example.com"
                 },
                 scope
               )

      assert %Ecto.Changeset{valid?: true} =
               Notifier.changeset(
                 %Notifier{},
                 %{
                   name: "Hook",
                   type: :webhook,
                   url: "https://hooks.example.com/pulseops"
                 },
                 scope
               )
    end

    test "defaults are enabled true and scoped to the organization" do
      scope = organization_scope_fixture()

      changeset =
        Notifier.changeset(
          %Notifier{},
          %{
            name: "Hook",
            type: :webhook,
            url: "https://hooks.example.com/pulseops"
          },
          scope
        )

      assert Ecto.Changeset.get_field(changeset, :enabled) == true
      assert changeset.changes.organization_id == scope.organization.id
    end
  end
end
