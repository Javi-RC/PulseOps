defmodule PulseOpsWeb.NotifierLiveTest do
  use PulseOpsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PulseOps.NotificationsFixtures

  alias Ecto.Changeset
  alias PulseOps.Accounts.User
  alias PulseOps.Notifications
  alias PulseOps.Organizations.Membership
  alias PulseOps.Repo

  setup :register_and_log_in_user_with_org

  defp notifiers_path(scope), do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers"

  defp new_notifier_path(scope),
    do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers/new"

  defp edit_notifier_path(scope, notifier),
    do: ~p"/orgs/#{scope.organization.slug}/settings/notifiers/#{notifier.id}/edit"

  defp user_email(user_id), do: Repo.get!(User, user_id).email

  describe "index" do
    test "shows the empty state until a notifier exists", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, notifiers_path(scope))

      assert html =~ "Nobody has been told yet"
      assert html =~ "Add a notifier"
      assert has_element?(live, "#new-notifier-link")
    end

    test "lists each notifier with its type, scope and assigned people", %{
      conn: conn,
      scope: scope
    } do
      member = assignee_id_fixture(scope)
      email = user_email(member)
      webhook = notifier_fixture(scope)
      email_notifier = notifier_fixture(scope, %{type: :email, assignee_ids: [member]})

      {:ok, live, html} = live(conn, notifiers_path(scope))

      assert html =~ webhook.name
      assert html =~ webhook.url
      assert html =~ "All services"
      assert html =~ email_notifier.name
      assert html =~ email
      assert has_element?(live, "#notifier-#{webhook.id}")
      assert has_element?(live, "#notifier-#{email_notifier.id}")
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
            secret_token: "s3cret",
            service_id: ""
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
      assert notifier.service_id == nil
    end

    test "creates an email notifier with assigned members and an unchecked box means disabled", %{
      conn: conn,
      scope: scope
    } do
      member_a = assignee_id_fixture(scope)
      email_a = user_email(member_a)
      assignee_id_fixture(scope)

      {:ok, live, _html} = live(conn, new_notifier_path(scope))

      form =
        live
        |> form("#notifier-form", %{notifier: %{type: "email"}})
        |> render_change()

      assert form =~ "Assigned members"

      {:ok, _live, html} =
        live
        |> form("#notifier-form", %{
          notifier: %{
            name: "On-call",
            type: "email",
            assignee_ids: [member_a],
            enabled: "false"
          }
        })
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert html =~ "Notifier created"
      assert html =~ email_a

      assert [notifier] = Notifications.list_notifiers(scope)
      assert notifier.type == :email
      assert notifier.assigned_users |> Enum.map(& &1.id) == [member_a]
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
      assert html =~ "must be a valid http or https URL"
    end
  end

  describe "edit" do
    test "switches a webhook to an email, pauses it and assigns members", %{
      conn: conn,
      scope: scope
    } do
      notifier = notifier_fixture(scope)
      member = assignee_id_fixture(scope)

      {:ok, live, html} = live(conn, edit_notifier_path(scope, notifier))
      assert html =~ "Edit notifier"
      assert html =~ notifier.name

      form =
        live
        |> form("#notifier-form", %{notifier: %{type: "email"}})
        |> render_change()

      assert form =~ "Assigned members"

      {:ok, _live, html} =
        live
        |> form("#notifier-form", %{
          notifier: %{type: "email", assignee_ids: [member], enabled: "false"}
        })
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert html =~ "Notifier updated"

      assert updated = Repo.reload!(notifier) |> Repo.preload(:assigned_users)
      assert updated.type == :email
      assert updated.assigned_users |> Enum.map(& &1.id) == [member]
      assert updated.enabled == false
      assert updated.secret_token == nil
    end

    test "never puts the stored secret token into the page, and keeps it on save", %{
      conn: conn,
      scope: scope
    } do
      notifier = notifier_fixture(scope, %{secret_token: "a-recognisable-token"})

      {:ok, live, html} = live(conn, edit_notifier_path(scope, notifier))

      # A password input still has a value attribute, and the core input fills it
      # from the field — so the token used to be one "view source" away.
      refute html =~ "a-recognisable-token"
      assert html =~ "A token is set"

      changed =
        live
        |> form("#notifier-form", %{notifier: %{name: "Renamed"}})
        |> render_change()

      refute changed =~ "a-recognisable-token"

      {:ok, _live, _html} =
        live
        |> form("#notifier-form", %{notifier: %{name: "Renamed"}})
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert Repo.reload!(notifier).name == "Renamed"
      assert Repo.reload!(notifier).secret_token == "a-recognisable-token"
    end

    test "can remove the stored secret token", %{conn: conn, scope: scope} do
      notifier = notifier_fixture(scope, %{secret_token: "a-recognisable-token"})

      {:ok, live, _html} = live(conn, edit_notifier_path(scope, notifier))

      {:ok, _live, _html} =
        live
        |> form("#notifier-form", %{notifier: %{clear_secret_token: "true"}})
        |> render_submit()
        |> follow_redirect(conn, notifiers_path(scope))

      assert Repo.reload!(notifier).secret_token == nil
    end
  end
end
