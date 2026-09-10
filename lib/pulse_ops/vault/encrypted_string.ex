defmodule PulseOps.Vault.EncryptedString do
  @moduledoc """
  A string field that is only ever in the clear in memory: encrypted by
  `PulseOps.Vault` on its way into the database, decrypted on its way out.

  A value that will not decrypt fails the load loudly instead of reading as nil.
  Silently dropping a webhook's token would turn "the key base changed" into
  deliveries failing somewhere else, later, for a reason nobody can see.
  """

  use Ecto.Type

  alias PulseOps.Vault

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, Vault.encrypt(value)}
  def dump(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(value) when is_binary(value), do: Vault.decrypt(value)
  def load(_value), do: :error
end
