defmodule PulseOpsWeb.AuthThrottleByAddressTest do
  @moduledoc """
  Limits keyed on the client's address. Separate from the per-email tests, and
  not async, because whether the proxy is trusted is application env — and
  every other test in the suite comes from 127.0.0.1.
  """

  use PulseOpsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PulseOps.AccountsFixtures

  setup %{conn: conn} do
    Application.put_env(:pulse_ops, :trusted_proxy, true)
    on_exit(fn -> Application.put_env(:pulse_ops, :trusted_proxy, false) end)

    # An address of this test's own, so the counters it fills belong to nobody
    # else. The left-hand entry is what a client might claim; only the rightmost,
    # appended by the proxy, is believed.
    n = System.unique_integer([:positive])
    address = "198.18.#{rem(div(n, 250), 250)}.#{rem(n, 250) + 1}"

    %{conn: put_req_header(conn, "x-forwarded-for", "192.0.2.1, #{address}")}
  end

  defp failed_login(conn) do
    conn
    |> post(~p"/users/log-in", %{
      "user" => %{"email" => unique_user_email(), "password" => "wrong-password"}
    })
    |> then(&Phoenix.Flash.get(&1.assigns.flash, :error))
  end

  test "one address trying many different emails is refused", %{conn: conn} do
    for _attempt <- 1..50, do: assert(failed_login(conn) == "Invalid email or password")

    assert failed_login(conn) =~ "Too many attempts"
  end

  test "the address is not believed unless the proxy is trusted", %{conn: conn} do
    Application.put_env(:pulse_ops, :trusted_proxy, false)

    for _attempt <- 1..51, do: assert(failed_login(conn) == "Invalid email or password")
  end

  test "magic link requests from one address are limited across emails", %{conn: conn} do
    request_link = fn ->
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: unique_user_email()})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      html
    end

    for _request <- 1..20, do: assert(request_link.() =~ "If your email is in our system")

    assert request_link.() =~ "Too many attempts"
  end

  test "registrations from one address are limited across emails", %{conn: conn} do
    register = fn ->
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      lv
      |> form("#registration_form", user: valid_user_attributes(email: unique_user_email()))
      |> render_submit()
    end

    for _registration <- 1..10 do
      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = register.()
    end

    assert register.() =~ "Too many attempts"
  end
end
