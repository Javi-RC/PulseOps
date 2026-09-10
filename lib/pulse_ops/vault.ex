defmodule PulseOps.Vault do
  @moduledoc """
  Encrypts the secrets PulseOps has to keep *and* hand back — a webhook's bearer
  token is sent on every delivery, so unlike an API token it cannot be reduced
  to a hash (ADR-018).

  AES-256-GCM, so a ciphertext that has been altered is refused rather than
  decrypted into something else. A fresh random IV for every value, so two
  notifiers sharing a token are not visibly the same in the table.

  The key is derived from a key base in the application environment — in
  production, the `SECRET_KEY_BASE` the endpoint already requires. Rotating that
  value makes every stored secret unreadable; see ADR-018.

  A ciphertext is `<<version, iv::12, tag::16, ciphertext::binary>>`. The version
  byte is there so the format can change without guessing what a row holds.
  """

  alias Plug.Crypto.KeyGenerator

  @version 1
  @iv_bytes 12
  @tag_bytes 16
  # Binds a ciphertext to this purpose, so bytes lifted from some other use of
  # the same key are refused.
  @aad "PulseOps.Vault.v1"
  @salt "PulseOps.Vault encryption key"

  @doc """
  Encrypts a value under the configured key base, or under `key_base` if given.
  """
  @spec encrypt(binary(), binary()) :: binary()
  def encrypt(plaintext, key_base \\ key_base()) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key(key_base),
        iv,
        plaintext,
        @aad,
        @tag_bytes,
        true
      )

    <<@version, iv::binary, tag::binary, ciphertext::binary>>
  end

  @doc """
  Decrypts what `encrypt/2` produced. Anything else — a tampered value, a value
  from another key base, bytes that were never ours — is `:error`.
  """
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | :error
  def decrypt(value, key_base \\ key_base())

  def decrypt(
        <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>,
        key_base
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key(key_base),
           iv,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_value, _key_base), do: :error

  defp key_base do
    :pulse_ops
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:secret_key_base)
  end

  # PBKDF2 is deliberately slow, and a page listing notifiers decrypts one per
  # row. The derived key is remembered per key base; persistent_term suits a
  # value written once and read constantly. Keyed by a hash so the key base
  # itself is not what sits in the term storage.
  defp key(key_base) do
    cache_key = {__MODULE__, :crypto.hash(:sha256, key_base)}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        key = KeyGenerator.generate(key_base, @salt, length: 32)
        :persistent_term.put(cache_key, key)
        key

      key ->
        key
    end
  end
end
