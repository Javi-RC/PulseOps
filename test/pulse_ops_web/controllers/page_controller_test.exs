defmodule PulseOpsWeb.PageControllerTest do
  use PulseOpsWeb.ConnCase

  describe "GET / as a visitor" do
    test "explains what PulseOps does", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Know a service is down before somebody tells you"
      assert html =~ "One process per service"
      # No trace of the framework's welcome page.
      refute html =~ "Peace of mind"
      refute html =~ "phoenixframework.org"
    end

    test "offers a way in", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~p"/users/register"
      assert html =~ ~p"/users/log-in"
    end
  end

  describe "GET / when signed in" do
    setup :register_and_log_in_user_with_org

    test "goes straight to the dashboard", %{conn: conn, scope: scope} do
      conn = get(conn, ~p"/")

      # Somebody with an account did not come back for the marketing page.
      assert redirected_to(conn) == ~p"/orgs/#{scope.organization.slug}"
    end
  end

  describe "the browser tab" do
    test "is named after the product, not the framework", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "· PulseOps"
      refute html =~ "Phoenix Framework"
    end
  end

  describe "the application shell" do
    setup :register_and_log_in_user_with_org

    test "renders exactly one navigation", %{conn: conn, scope: scope} do
      html = conn |> get(~p"/orgs/#{scope.organization.slug}") |> html_response(200)

      # The root layout used to render the generated user menu on top of the
      # application header, giving every page two stacked navs.
      assert html =~ "Dashboard"
      assert length(String.split(html, "app-drawer")) - 1 > 0
      refute html =~ "menu menu-horizontal"
    end

    test "shows the organization switcher and the sections", %{conn: conn, scope: scope} do
      html = conn |> get(~p"/orgs/#{scope.organization.slug}") |> html_response(200)

      assert html =~ scope.organization.name
      assert html =~ "Services"
      assert html =~ "Incidents"
      assert html =~ "Members"
      assert html =~ "New organization"
    end

    test "hides settings from somebody who cannot manage the organization", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      demote_to_viewer(scope, user)

      html = conn |> get(~p"/orgs/#{scope.organization.slug}") |> html_response(200)

      refute html =~ ~p"/orgs/#{scope.organization.slug}/settings"
    end
  end

  defp demote_to_viewer(scope, user) do
    PulseOps.Repo.get_by!(PulseOps.Organizations.Membership,
      organization_id: scope.organization.id,
      user_id: user.id
    )
    |> Ecto.Changeset.change(role: :viewer)
    |> PulseOps.Repo.update!()
  end
end
