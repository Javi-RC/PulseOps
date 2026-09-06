defmodule PulseOps.Monitoring.HealthCheck.Result do
  @moduledoc """
  What a single probe observed: the HTTP status if there was one, how long it
  took, and the failure reason if it did not succeed.
  """

  @type t :: %__MODULE__{
          http_status: pos_integer() | nil,
          response_time_ms: non_neg_integer() | nil,
          error: String.t() | nil
        }

  defstruct http_status: nil, response_time_ms: nil, error: nil
end
