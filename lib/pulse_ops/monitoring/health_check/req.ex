defmodule PulseOps.Monitoring.HealthCheck.Req do
  @moduledoc """
  The real health check client, backed by Req.
  """

  @behaviour PulseOps.Monitoring.HealthCheck

  alias PulseOps.Monitoring.HealthCheck.Result

  @impl true
  def check(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    started = System.monotonic_time(:millisecond)

    result =
      Req.get(url,
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        # Retries are the state machine's decision, not the client's: a silent
        # retry here would hide a failure the monitor needs to count.
        retry: false,
        # A redirect to a healthy page would mask an unhealthy endpoint.
        redirect: false,
        decode_body: false
      )

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, %Result{http_status: status, response_time_ms: elapsed}}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         %Result{
           http_status: status,
           response_time_ms: elapsed,
           error: "unexpected HTTP status #{status}"
         }}

      {:error, exception} ->
        {:error, %Result{response_time_ms: elapsed, error: describe(exception)}}
    end
  end

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(other), do: inspect(other)
end
