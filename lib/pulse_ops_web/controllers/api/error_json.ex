defmodule PulseOpsWeb.Api.ErrorJSON do
  @moduledoc """
  The one error shape the API answers with, so a client can branch on `code`
  rather than parsing prose.
  """

  def error(%{code: code, message: message}) do
    %{error: %{code: code, message: message}}
  end

  def invalid(%{changeset: changeset}) do
    %{
      error: %{
        code: "invalid",
        message: "Some fields are not acceptable.",
        fields: Ecto.Changeset.traverse_errors(changeset, &translate/1)
      }
    }
  end

  defp translate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
      opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
    end)
  end
end
