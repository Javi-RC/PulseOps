defmodule PulseOpsWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import PulseOpsWeb.CoreComponents

  describe "button/1" do
    test "gives each variant its own look" do
      for {variant, class} <- [
            {"primary", "btn-primary"},
            {"secondary", "btn-soft"},
            {"ghost", "btn-ghost"},
            {"outline", "btn-outline"},
            {"danger", "btn-error"},
            {"danger-ghost", "btn-ghost text-error"}
          ] do
        assigns = %{variant: variant}

        html =
          rendered_to_string(~H"""
          <.button variant={@variant}>Go</.button>
          """)

        assert html =~ ~s(class="btn #{class}"), "#{variant} should render #{class}"
      end
    end

    test "is secondary unless told otherwise" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button>Cancel</.button>
        """)

      assert html =~ ~r/<button[^>]*class="btn btn-soft"/
    end

    test "adds layout classes instead of losing its own look to them" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="primary" size="sm" class="w-full">Accept</.button>
        """)

      assert html =~ ~s(class="btn btn-primary btn-sm w-full")
    end

    test "becomes a link when it navigates, keeping its look and attributes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button navigate="/orgs/acme/services/new" id="new-service" variant="primary">
          New service
        </.button>
        """)

      assert html =~ ~r/<a[^>]*href="\/orgs\/acme\/services\/new"/
      assert html =~ ~s(id="new-service")
      assert html =~ "btn btn-primary"
      refute html =~ "<button"
    end

    test "passes a type through, so it need not submit the form it sits in" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button type="button" phx-click="dismiss">Done</.button>
        """)

      assert html =~ ~s(type="button")
      assert html =~ ~s(phx-click="dismiss")
    end
  end
end
