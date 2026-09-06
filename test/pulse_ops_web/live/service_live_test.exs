defmodule PulseOpsWeb.ServiceLiveTest do
  use PulseOpsWeb.ConnCase

  import Phoenix.LiveViewTest
  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  @create_attrs %{
    enabled: true,
    name: "Payments API",
    description: "some description",
    url: "https://payments.example.com/health",
    environment: :production,
    check_interval_ms: 30_000,
    timeout_ms: 5_000
  }
  @update_attrs %{
    enabled: false,
    name: "Payments API v2",
    description: "some updated description",
    url: "https://payments.example.com/healthz",
    environment: :staging,
    check_interval_ms: 60_000,
    timeout_ms: 10_000
  }
  # environment is a select with no blank option, so the form can never submit it
  # empty; leaving it out keeps these attrs to what a browser could actually send.
  @invalid_attrs %{
    enabled: false,
    name: nil,
    description: nil,
    url: nil,
    check_interval_ms: nil,
    timeout_ms: nil
  }

  setup :register_and_log_in_user_with_org

  defp create_service(%{scope: scope}) do
    service = service_fixture(scope)

    %{service: service}
  end

  describe "Index" do
    setup [:create_service]

    test "lists all services", %{conn: conn, service: service, scope: scope} do
      {:ok, _index_live, html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services")

      assert html =~ "Listing Services"
      assert html =~ service.name
    end

    test "saves new service", %{conn: conn, scope: scope} do
      {:ok, index_live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Service")
               |> render_click()
               |> follow_redirect(conn, ~p"/orgs/#{scope.organization.slug}/services/new")

      assert render(form_live) =~ "New Service"

      assert form_live
             |> form("#service-form", service: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#service-form", service: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/orgs/#{scope.organization.slug}/services")

      html = render(index_live)
      assert html =~ "Service created successfully"
      assert html =~ "Payments API"
    end

    test "updates service in listing", %{conn: conn, service: service, scope: scope} do
      {:ok, index_live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#services-#{service.id} a", "Edit")
               |> render_click()
               |> follow_redirect(
                 conn,
                 ~p"/orgs/#{scope.organization.slug}/services/#{service}/edit"
               )

      assert render(form_live) =~ "Edit Service"

      assert form_live
             |> form("#service-form", service: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#service-form", service: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/orgs/#{scope.organization.slug}/services")

      html = render(index_live)
      assert html =~ "Service updated successfully"
      assert html =~ "Payments API v2"
    end

    test "deletes service in listing", %{conn: conn, service: service, scope: scope} do
      {:ok, index_live, _html} = live(conn, ~p"/orgs/#{scope.organization.slug}/services")

      assert index_live |> element("#services-#{service.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#services-#{service.id}")
    end
  end

  describe "tenancy" do
    setup [:create_service]

    test "redirects a user who is not a member of the organization", %{conn: conn} do
      outsider_scope = organization_scope_fixture()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, ~p"/orgs/#{outsider_scope.organization.slug}/services")

      assert message == "Organization not found."
    end

    test "redirects for an organization that does not exist", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, ~p"/orgs/no-such-org/services")

      # Same message as the forbidden case: the route must not reveal which
      # organizations exist.
      assert message == "Organization not found."
    end

    test "does not expose another organization's service by id", %{conn: conn, scope: scope} do
      other_scope = organization_scope_fixture()
      other_service = service_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{other_service}")
      end
    end
  end

  describe "Show" do
    setup [:create_service]

    test "displays service", %{conn: conn, service: service, scope: scope} do
      {:ok, _show_live, html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}")

      assert html =~ "Show Service"
      assert html =~ service.name
    end

    test "updates service and returns to show", %{conn: conn, service: service, scope: scope} do
      {:ok, show_live, _html} =
        live(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(
                 conn,
                 ~p"/orgs/#{scope.organization.slug}/services/#{service}/edit?return_to=show"
               )

      assert render(form_live) =~ "Edit Service"

      assert form_live
             |> form("#service-form", service: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#service-form", service: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/orgs/#{scope.organization.slug}/services/#{service}")

      html = render(show_live)
      assert html =~ "Service updated successfully"
      assert html =~ "Payments API v2"
    end
  end
end
