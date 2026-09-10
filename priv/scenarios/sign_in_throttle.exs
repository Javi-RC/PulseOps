# Drives password sign-in throttling against the running application, over real
# HTTP: the login page, its CSRF token, the session cookie, and the form post —
# nothing called directly.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/sign_in_throttle.exs
#
# Takes a few seconds. Leaves its scenario users behind in the development
# database.

Logger.configure(level: :warning)

alias PulseOps.Accounts

defmodule Scenario do
  def step(text), do: IO.puts("\n== #{text}")

  def check(true, text), do: IO.puts("   PASS  #{text}")

  def check(false, text) do
    IO.puts("   FAIL  #{text}")
    System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end
end

defmodule Browser do
  @base "http://localhost:4000"

  # A browser session: the cookie and the CSRF token the login page handed out.
  def open(headers \\ []) do
    response = Req.get!(@base <> "/users/log-in", headers: headers, retry: false)

    token =
      case Regex.run(~r/name="csrf-token"\s+content="([^"]+)"/, to_string(response.body)) do
        [_, token] ->
          token

        nil ->
          raise "no CSRF token on the login page (HTTP #{response.status}): " <>
                  String.slice(to_string(response.body), 0, 400)
      end

    %{cookie: cookie(response, nil), token: token, headers: headers}
  end

  # Where the login form sent us: "/" for a signed-in user, back to the login
  # page when refused.
  def sign_in(session, email, password) do
    response =
      Req.post!(@base <> "/users/log-in",
        form: [_csrf_token: session.token, "user[email]": email, "user[password]": password],
        headers: [{"cookie", session.cookie} | session.headers],
        redirect: false,
        retry: false
      )

    session = %{session | cookie: cookie(response, session.cookie)}
    {location(response), session}
  end

  # The flash is kept in the session, so reading it means following the redirect
  # with the cookie the post set.
  def flash_after(session, path) do
    Req.get!(@base <> path, headers: [{"cookie", session.cookie}], retry: false).body
  end

  defp location(response), do: response |> Req.Response.get_header("location") |> List.first()

  defp cookie(response, previous) do
    case Req.Response.get_header(response, "set-cookie") do
      [set_cookie | _] -> set_cookie |> String.split(";") |> List.first()
      [] -> previous
    end
  end
end

suffix = System.os_time(:millisecond)
password = "a sufficiently long password"

make_user = fn name ->
  {:ok, user} = Accounts.register_user(%{email: "#{name}-#{suffix}@pulseops.test"})
  {:ok, {user, _tokens}} = Accounts.update_user_password(user, %{password: password})
  user
end

target = make_user.("throttle-target")
bystander = make_user.("throttle-bystander")

Scenario.step("The right password signs in")
{location, _session} = Browser.sign_in(Browser.open(), target.email, password)
Scenario.check(location == "/", "redirected to #{inspect(location)}")

Scenario.step("Five wrong passwords for one email")
session = Browser.open()

session =
  Enum.reduce(1..5, session, fn n, session ->
    {location, session} = Browser.sign_in(session, target.email, "wrong-#{n}")
    Scenario.check(location == "/users/log-in", "attempt #{n} refused as a wrong password")
    session
  end)

Scenario.step("The right password is now refused too")
{location, session} = Browser.sign_in(session, target.email, password)
Scenario.check(location == "/users/log-in", "not signed in: redirected to #{inspect(location)}")

Scenario.check(
  Browser.flash_after(session, "/users/log-in") =~ "Too many attempts",
  "and told why"
)

Scenario.step("Another email is unaffected")
{location, _session} = Browser.sign_in(Browser.open(), bystander.email, password)
Scenario.check(location == "/", "bystander signs in: redirected to #{inspect(location)}")

Scenario.step("Without a trusted proxy, a forwarded address is not believed")
Application.put_env(:pulse_ops, :trusted_proxy, false)
spoofed = [{"x-forwarded-for", "198.51.100.77"}]
session = Browser.open(spoofed)

session =
  Enum.reduce(1..51, session, fn n, session ->
    {_location, session} = Browser.sign_in(session, "nobody-#{n}-#{suffix}@pulseops.test", "x")
    session
  end)

Scenario.check(
  not (Browser.flash_after(session, "/users/log-in") =~ "Too many attempts"),
  "51 emails from one claimed address are all still tried"
)

Scenario.step("Behind a trusted proxy, one address trying many emails is cut off")
Application.put_env(:pulse_ops, :trusted_proxy, true)
forwarded = [{"x-forwarded-for", "192.0.2.1, 198.51.100.#{rem(suffix, 200) + 1}"}]
session = Browser.open(forwarded)

session =
  Enum.reduce(1..50, session, fn n, session ->
    {_location, session} = Browser.sign_in(session, "stranger-#{n}-#{suffix}@pulseops.test", "x")
    session
  end)

{location, session} = Browser.sign_in(session, bystander.email, password)
Scenario.check(location == "/users/log-in", "the 51st attempt from that address is refused")

Scenario.check(
  Browser.flash_after(session, "/users/log-in") =~ "Too many attempts",
  "even for an account with the right password"
)

{location, _session} = Browser.sign_in(Browser.open(), bystander.email, password)
Scenario.check(location == "/", "while the same account from elsewhere still signs in")

Application.put_env(:pulse_ops, :trusted_proxy, false)
IO.puts("\n   done")
