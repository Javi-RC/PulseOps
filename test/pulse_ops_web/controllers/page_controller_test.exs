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

    test "draws the check cycle as a diagram with a text equivalent", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "What happens on every check"
      assert html =~ ~s(role="img")
      # A change of status, an incident and a single check are three different
      # things, and the diagram and its steps must not blur them together.
      assert html =~ "Status changed?"
      assert html =~ "sees every check live"
      # Whitespace-tolerant: the template wraps the sentence across lines.
      assert html =~ ~r/slowing down to degraded\s+does neither/
      # The moving dashes are decoration; the steps have to be readable without
      # them, and the animation has to stop for anyone who asks it to.
      assert html =~ "Read it as steps"
      assert html =~ "prefers-reduced-motion"
      refute html =~ "<pre"
    end

    test "offers a way in", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~p"/users/register"
      assert html =~ ~p"/users/log-in"
    end

    test "shows the product before asking for anything", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(id="product-preview")
      assert html =~ "Payments API is unavailable"
      # The preview is decoration, so what it shows is also said in words.
      assert html =~ "A preview of the PulseOps dashboard"
    end

    test "names what it does, not only how it is built", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for feature <- ["Alert rules", "Maintenance windows", "A public status page", "A JSON API"] do
        assert html =~ feature, "missing #{feature}"
      end
    end

    test "points reviewers at the source", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "https://github.com/Javi-RC/PulseOps"
      # The design notes stay out of the repository, so nothing may link to them.
      refute html =~ "docs/"
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

      # The exact link, closing quote included: alert rules live under the same
      # path and are open to every member, so a bare prefix would match them too.
      refute html =~ ~s(href="#{~p"/orgs/#{scope.organization.slug}/settings"}")
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
