defmodule PulseOps.Mailer do
  use Swoosh.Mailer, otp_app: :pulse_ops

  @doc """
  The default sender every outgoing mail uses, as `{name, address}`, read from
  config.
  """
  def from_default do
    config = Application.get_env(:pulse_ops, __MODULE__, [])
    {config[:from_name] || "PulseOps", config[:from] || "contact@example.com"}
  end
end
