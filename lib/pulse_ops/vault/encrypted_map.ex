defmodule PulseOps.Vault.EncryptedMap do
  @moduledoc """
  A map field that is only ever in the clear in memory: JSON-encoded and
  encrypted by `PulseOps.Vault` on its way into the database, decrypted and
  decoded on its way out.

  Keys come back as strings, as they did from the `jsonb` column this replaces.
  A value that will not decrypt fails the load loudly — see
  `PulseOps.Vault.EncryptedString` for why that is the safer failure.
  """

  use Ecto.Type

  alias PulseOps.Vault

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value) when is_map(value), do: {:ok, value |> Jason.encode!() |> Vault.encrypt()}
  def dump(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    with {:ok, json} <- Vault.decrypt(value),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _unreadable -> :error
    end
  end

  def load(_value), do: :error
end
