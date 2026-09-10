defmodule PulseOps.VaultTest do
  use ExUnit.Case, async: true

  alias PulseOps.Vault

  test "what is encrypted decrypts back to itself" do
    assert {:ok, "s3cret"} = "s3cret" |> Vault.encrypt() |> Vault.decrypt()
  end

  test "the ciphertext does not contain the plaintext" do
    refute Vault.encrypt("a-very-recognisable-token") =~ "a-very-recognisable-token"
  end

  test "the same value encrypts differently every time" do
    # A fixed IV would let anyone with the table see which notifiers share a
    # token, and would break GCM's guarantees outright.
    refute Vault.encrypt("same") == Vault.encrypt("same")
  end

  test "a tampered ciphertext is refused, not decrypted into garbage" do
    <<head::binary-size(20), byte, rest::binary>> = Vault.encrypt("s3cret")
    tampered = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>

    assert Vault.decrypt(tampered) == :error
  end

  test "anything that is not a ciphertext of ours is refused" do
    assert Vault.decrypt("s3cret") == :error
    assert Vault.decrypt(<<>>) == :error
  end

  test "a value encrypted under another key base is refused" do
    other = Vault.encrypt("s3cret", "a-different-secret-key-base-of-sufficient-length-0123456789")

    assert Vault.decrypt(other) == :error
  end
end
