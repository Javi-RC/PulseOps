defmodule PulseOpsWeb.NotifierLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.NotificationsFixtures

  alias Ecto.Changeset
  alias PulseOps.Notifications
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp notifiers_path(scope), do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers"

  defp new_notifier_path(scope),
    do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers/new"

  defp edit_notifier_path(scope, notifier),
    do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers/#{notifier.id}/edit"

  describe "index" do
    test "shows the empty state until a notifier exists", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, notifiers_path(scope))

      assert html =~ "Nobody has been told yet"
      assert html =~ "Add a notifier"
      assert has_element?(live, "#new-notifier-link")
    end

    test "lists each notifier with its type and destination", %{conn: conn, scope: scope} do
      webhook = notifier_fixture(scope)
      email = notifier_fixture(scope, %{type: :email, recipient: "oncall@example.com"})

      {:ok, live, html} = live(conn, notifiers_path(scope))

      assert html =~ webhook.name
      assert html =~ webhook.url
      assert html =~ email.recipient
      assert html =~ "Active"
      assert has_element?(live, "#notifier-#{webhook.id}")
      assert has_element?(live, "#notifier-#{email.id}")
    end

    test "marks a paused notifier", %{conn: conn, scope: scope} do
      notifier = notifier_fixture(scope, %{enabled: false})

      {:ok, _live, html} = live(conn, notifiers_path(scope))
      assert html =~ "Paused"
      assert html =~ notifier.name
    end

    test "deletes a notifier", %{conn: conn, scope: scope} do
      notifier = notifier_fixture(scope)

      {:ok, live, _html} = live(conn, notifiers_path(scope))
      assert has_element?(live, "#notifier-#{notifier.id}")

      live
      |> element("#notifier-#{notifier.id} button[phx-click=\"delete\"]")
      |> render_click()

      assert Notifications.list_notifiers(scope) == []
      refute has_element?(live, "#notifier-#{notifier.id}")
      assert render(live) =~ "Nobody has been told yet"
    end

    test "a viewer sees the notifiers without the management controls", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      notifier = notifier_fixture(scope)

      Repo.get_by!(Membership, organization_id: scope.organization.id, user_id: user.id)
      |> Changeset.change(role: :viewer)
      |> Repo.update!()

      {:ok, live, html} = live(conn, notifiers_path(scope))

      assert html =~ notifier.name
      refute has_element?(live, "#new-notifier-link")
      refute has_element?(live, "#notifier-#{notifier.id} a[href$=\"/edit\"]")
      refute has_element?(live, "#notifier-#{notifier.id} button[phx-click=\"delete\"]")
    end
  end

  describe "new" do
    test "creates a webhook notifier", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, new_notifier_path(scope))
      assert html =~ "New notifier"

      {:ok, _live, html} =
        live
        |> form("#notifier-form", %{
          notifier: %{
            name: "Ops chat",
            type: "webhook",
            url: "https://hooks.example.com/incidents",
            secret_token: "s3cret"
          }
        })
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert html =~ "Notifier created"

      assert [notifier] = Notifications.list_notifiers(scope)
      assert notifier.name == "Ops chat"
      assert notifier.type == :webhook
      assert notifier.url == "https://hooks.example.com/incidents"
      assert notifier.secret_token == "s3cret"
      assert notifier.enabled == true
    end

    test "creates an email notifier and an unchecked box means disabled", %{
      conn: conn,
      scope: scope
    } do
      {:ok, live, _html} = live(conn, new_notifier_path(scope))

      form =
        live
        |> form("#notifier-form", %{notifier: %{type: "email"}})
        |> render_change()

      assert form =~ "Recipient"

      {:ok, _live, html} =
        live
        |> form("#notifier-form", %{
          notifier: %{
            name: "On-call",
            type: "email",
            recipient: "oncall@example.com",
            enabled: "false"
          }
        })
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert html =~ "Notifier created"

      assert [notifier] = Notifications.list_notifiers(scope)
      assert notifier.type == :email
      assert notifier.recipient == "oncall@example.com"
      assert notifier.enabled == false
    end

    test "reports validation errors", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, new_notifier_path(scope))

      html =
        live
        |> form("#notifier-form", %{
          notifier: %{name: "", type: "webhook", url: "not-a-url"}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
      assert html =~ "must be an http(s) URL"
    end
  end

  describe "edit" do
    test "switches a webhook to an email and pauses it", %{conn: conn, scope: scope} do
      notifier = notifier_fixture(scope)

      {:ok, live, html} = live(conn, edit_notifier_path(scope, notifier))
      assert html =~ "Edit notifier"
      assert html =~ notifier.name

      form =
        live
        |> form("#notifier-form", %{notifier: %{type: "email"}})
        |> render_change()

      assert form =~ "Recipient"

      {:ok, _live, html} =
        live
        |> form("#notifier-form", %{
          notifier: %{type: "email", recipient: "pager@example.com", enabled: "false"}
        })
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert html =~ "Notifier updated"

      assert updated = Repo.reload!(notifier)
      assert updated.type == :email
      assert updated.recipient == "pager@example.com"
      assert updated.enabled == false
      assert updated.secret_token == nil
    end
  end
end
