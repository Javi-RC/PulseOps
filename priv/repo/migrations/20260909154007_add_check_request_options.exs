defmodule PulseOps.Repo.Migrations.AddCheckRequestOptions do
  use Ecto.Migration

  # Until now every probe was `Req.get(url)` with no options, so PulseOps could
  # only watch endpoints that are public, answer GET, and say everything they
  # mean in the status line. That leaves out most real health endpoints: the ones
  # behind a token, the ones that answer 204 or 401, and the ones that return 200
  # with `{"status":"degraded"}` in the body — which is the failure mode a status
  # check exists to catch and the one a bare status code cannot see.
  #
  # Every column defaults to what the hardcoded behaviour already did, so an
  # existing service keeps being probed exactly as before.
  def change do
    alter table(:services) do
      add :http_method, :string, null: false, default: "get"

      # A JSON object of header name to value. Stored as sent, which means an
      # Authorization header lives in the database in plain text, exactly like
      # notifiers.secret_token does — the same known debt, not a new one.
      add :request_headers, :map, null: false, default: %{}
      add :request_body, :text

      # Null means the previous rule: any 2xx is a success. An integer means
      # exactly that status, which is how you watch an endpoint whose healthy
      # answer is 204, or one that proves it is alive by answering 401.
      add :expected_status, :integer

      # Null means the body is not read. Text means it has to appear in the
      # response, which is the only way to catch a service that is up, answering
      # 200, and telling you in its payload that it is not well.
      add :body_assertion, :string
    end
  end
end
