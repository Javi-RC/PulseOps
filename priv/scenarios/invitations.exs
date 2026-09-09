# Drives the invitation flow against the running application, over real HTTP,
# including the email that carries the link.
#
#   docker compose run --rm -e PHX_SERVER=true web mix run priv/scenarios/invitations.exs
#
# The case worth watching is the GET. A mail scanner or a link prefetcher
# follows links in email; if merely fetching the page joined the organization,
# people would be joining organizations whose email they never opened.

Logger.configure(level: :warning)

alias PulseOps.Accounts
alias PulseOps.Organizations
alias PulseOps.Repo

defmodule Check do
  def step(text), do: IO.puts("\n== #{text}")
  def check(true, text), do: IO.puts("   PASS  #{text}")
  def check(false, text), do: IO.puts("   FAIL  #{text}")
end

suffix = System.os_time(:millisecond)
invited = "newcomer-#{suffix}@pulseops.test"

{:ok, inviter} = Accounts.register_user(%{email: "inviter-#{suffix}@pulseops.test"})
{:ok, organization} = Organizations.create_organization(inviter, %{name: "Invite Demo #{suffix}"})

scope =
  inviter
  |> PulseOps.Accounts.Scope.for_user()
  |> PulseOps.Accounts.Scope.put_organization(organization, :owner)

Check.step("Inviting an address with no account here")

{:ok, invitation, token} =
  Organizations.invite_member(
    scope,
    invited,
    :member,
    &"http://localhost:4000/invitations/#{&1}"
  )

Check.check(invitation.email == invited, "the invitation is recorded")
Check.check(invitation.hashed_token != token, "and only its hash is stored")

Check.check(
  Repo.get_by(PulseOps.Accounts.User, email: invited) == nil,
  "no account exists for them yet"
)

url = "http://localhost:4000/invitations/#{token}"

Check.step("Opening the link shows the offer and joins nobody")
page = Req.get!(url, retry: false)

Check.check(page.status == 200, "the page is readable with no session")
Check.check(String.contains?(page.body, organization.name), "it names the organization")
Check.check(String.contains?(page.body, "Accept invitation"), "and offers to accept")

# The important one: a GET must not have accepted anything.
Check.check(
  Repo.get_by(PulseOps.Accounts.User, email: invited) == nil,
  "fetching the page created no account — a mail scanner cannot accept for them"
)

Check.check(
  length(Organizations.list_pending_invitations(scope)) == 1,
  "and the invitation is still waiting"
)

Check.step("Accepting is a POST")

# The form carries a CSRF token, so drive it the way a browser would: read the
# token out of the page and send it back with the session cookie.
csrf =
  Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.body)
  |> case do
    [_whole, value] -> value
    _other -> nil
  end

Check.check(is_binary(csrf), "the form carries a CSRF token")

cookie =
  page.headers
  |> Map.get("set-cookie", [])
  |> Enum.map(&(&1 |> String.split(";") |> hd()))
  |> Enum.join("; ")

accepted =
  Req.post!("#{url}/accept",
    form: [_csrf_token: csrf],
    headers: [{"cookie", cookie}],
    redirect: false,
    retry: false
  )

Check.check(accepted.status in [302, 303], "it redirects after accepting")

user = Repo.get_by(PulseOps.Accounts.User, email: invited)
Check.check(user != nil, "the account now exists")
Check.check(user && user.confirmed_at != nil, "and is confirmed, because they held the link")

emails = Enum.map(Organizations.list_members(scope), & &1.user.email)
Check.check(invited in emails, "they are a member")
Check.check(Organizations.list_pending_invitations(scope) == [], "the invitation is spent")

Check.step("The link is single use")
second = Req.post!("#{url}/accept", form: [_csrf_token: csrf], headers: [{"cookie", cookie}], redirect: false, retry: false)
Check.check(second.status in [302, 303], "a second post is refused with a redirect")

Check.check(
  length(Organizations.list_members(scope)) == 2,
  "and no second membership was created"
)

Check.step("Clean up")
IO.puts("   done")
