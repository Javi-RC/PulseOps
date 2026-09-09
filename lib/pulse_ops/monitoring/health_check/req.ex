defmodule PulseOps.Monitoring.HealthCheck.Req do
  @moduledoc """
  The real health check client, backed by Req.

  ## What counts as healthy

  By default any 2xx, which is what this did when a probe was nothing but
  `Req.get(url)`. A service can narrow that in two ways, and both exist because
  a status line is often not enough to tell whether something is actually well:

    * `expected_status` — exactly this status and nothing else. It is how you
      watch an endpoint whose healthy answer is `204`, or one that proves it is
      alive by answering `401`.

    * `body_assertion` — this text has to appear in the response. It is the only
      way to catch the failure a status code cannot see: a service that is up,
      answering `200`, and saying in its payload that its database is gone.

  Both are checked after the status, so an unexpected status is reported as
  such rather than as a missing string.
  """

  @behaviour PulseOps.Monitoring.HealthCheck

  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.UrlGuard

  @impl true
  def check(url, opts \\ []) do
    case UrlGuard.validate(url) do
      :ok ->
        probe(url, opts)

      # Checked again here rather than trusting the changeset: the host can be
      # repointed at a private address after the service was saved, and the
      # probe runs on a schedule for as long as the service exists. Recorded as
      # a failed check, so the reason shows up on the service instead of the
      # probe silently never happening.
      {:error, reason} ->
        {:error, %Result{error: "blocked target: #{UrlGuard.message(reason)}"}}
    end
  end

  defp probe(url, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    started = System.monotonic_time(:millisecond)

    result = Req.request(request_options(url, opts, timeout))

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %Req.Response{} = response} ->
        judge(response, elapsed, opts)

      {:error, exception} ->
        {:error, %Result{response_time_ms: elapsed, error: describe(exception)}}
    end
  end

  defp request_options(url, opts, timeout) do
    [
      url: url,
      method: Keyword.get(opts, :method, :get),
      headers: Keyword.get(opts, :headers, []),
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      plug: plug(),
      # Retries are the state machine's decision, not the client's: a silent
      # retry here would hide a failure the monitor needs to count.
      retry: false,
      # A redirect to a healthy page would mask an unhealthy endpoint.
      redirect: false,
      decode_body: false
    ]
    |> put_body(Keyword.get(opts, :body))
  end

  defp put_body(options, body) when is_binary(body) and body != "",
    do: Keyword.put(options, :body, body)

  defp put_body(options, _body), do: options

  defp judge(%Req.Response{status: status} = response, elapsed, opts) do
    expected = Keyword.get(opts, :expected_status)
    assertion = Keyword.get(opts, :body_assertion)

    cond do
      not acceptable_status?(status, expected) ->
        {:error,
         %Result{
           http_status: status,
           response_time_ms: elapsed,
           error: status_error(status, expected)
         }}

      not body_matches?(response.body, assertion) ->
        {:error,
         %Result{
           http_status: status,
           response_time_ms: elapsed,
           error: "response body did not contain #{inspect(assertion)}"
         }}

      true ->
        {:ok, %Result{http_status: status, response_time_ms: elapsed}}
    end
  end

  defp acceptable_status?(status, nil), do: status in 200..299
  defp acceptable_status?(status, expected), do: status == expected

  defp status_error(status, nil), do: "unexpected HTTP status #{status}"
  defp status_error(status, expected), do: "expected HTTP status #{expected}, got #{status}"

  defp body_matches?(_body, nil), do: true
  defp body_matches?(_body, ""), do: true
  defp body_matches?(body, assertion) when is_binary(body), do: String.contains?(body, assertion)
  # A body that is not a binary cannot be searched, and saying so is better than
  # quietly passing a check the service asked for.
  defp body_matches?(_body, _assertion), do: false

  # The same seam the webhook sender uses: tests route the request through a
  # Req.Test plug so this module's own mapping of responses to results can be
  # exercised without the network. Everything else goes over the wire.
  defp plug do
    case Application.get_env(:pulse_ops, :health_check_transport, :http) do
      :stub -> {Req.Test, :health_check}
      :http -> nil
    end
  end

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(other), do: inspect(other)
end
