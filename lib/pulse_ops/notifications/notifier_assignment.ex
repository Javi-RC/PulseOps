defmodule PulseOps.Notifications.NotifierAssignment do
  @moduledoc """
  Links a notifier to a user it should reach.

  For an email notifier the assigned users are the recipients — each one receives
  their own copy. For a webhook the assignments are informational, recording who
  is responsible for the channel.
  """

  use Ecto.Schema

  alias PulseOps.Accounts.User
  alias PulseOps.Notifications.Notifier

  schema "notifier_assignments" do
    belongs_to :notifier, Notifier
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
