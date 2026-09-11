defmodule PulseOpsWeb.MemberLive.Index do
  @moduledoc """
  Who is in the organization and what each of them may do.

  The permission table at the bottom is not decoration: the roles are enforced
  in the contexts, and this is where a reader finds out what they mean.
  """

  use PulseOpsWeb, :live_view

  import PulseOpsWeb.UIComponents

  alias PulseOps.Organizations
  alias PulseOps.Organizations.Invitation
  alias PulseOps.Organizations.Membership

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Members")
     |> assign(:recipient, nil)
     |> assign(:form, to_form(%{"email" => "", "role" => "member"}, as: :member))
     |> load_members()}
  end

  @impl true
  def handle_event("add", %{"member" => %{"email" => email, "role" => role}}, socket) do
    case Organizations.add_member(socket.assigns.current_scope, email, role) do
      {:ok, membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{membership.user.email} added to the organization.")
         |> reset_form()
         |> load_members()}

      # Nobody is registered with that address, which is the common case and
      # used to be a dead end. One field does both: add whoever is already here,
      # invite whoever is not.
      {:error, :not_found} ->
        {:noreply, invite(socket, email, role)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message_for(reason))}
    end
  end

  # Says, before anything is sent, what the one field will do with this address.
  # It does tell somebody who manages members whether an address has an account
  # here — which they learn anyway the moment they submit, from the flash.
  def handle_event("preview", %{"member" => params}, socket) do
    if socket.assigns.can_manage? do
      {:noreply,
       socket
       |> assign(:form, to_form(params, as: :member))
       |> assign(:recipient, recipient(socket, params["email"]))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("withdraw", %{"id" => id}, socket) do
    case Organizations.revoke_invitation(socket.assigns.current_scope, String.to_integer(id)) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Invitation to #{invitation.email} withdrawn; its link stops working."
         )
         |> load_members()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message_for(reason))}
    end
  end

  def handle_event("set_role", %{"member_id" => id, "role" => role}, socket) do
    membership = Organizations.get_member!(socket.assigns.current_scope, id)

    case Organizations.update_member_role(socket.assigns.current_scope, membership, role) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{updated.user.email} is now #{updated.role}.")
         |> load_members()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message_for(reason))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    membership = Organizations.get_member!(socket.assigns.current_scope, id)

    case Organizations.remove_member(socket.assigns.current_scope, membership) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{membership.user.email} removed from the organization.")
         |> load_members()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, message_for(reason))}
    end
  end

  defp invite(socket, email, role) do
    scope = socket.assigns.current_scope

    case Organizations.invite_member(scope, email, role, &url(~p"/invitations/#{&1}")) do
      {:ok, invitation, _token} ->
        socket
        |> put_flash(:info, "Invitation sent to #{invitation.email}.")
        |> reset_form()
        |> load_members()

      {:error, reason} ->
        put_flash(socket, :error, message_for(reason))
    end
  end

  defp reset_form(socket) do
    socket
    |> assign(:form, to_form(%{"email" => "", "role" => "member"}, as: :member))
    |> assign(:recipient, nil)
  end

  defp load_members(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:members, Organizations.list_members(scope))
    |> assign(:invitations, Organizations.list_pending_invitations(scope))
    |> assign(:can_manage?, Organizations.can?(scope, :manage_organization))
  end

  defp message_for(:not_found), do: "That invitation no longer exists."

  defp message_for(:already_a_member), do: "That person is already a member."

  defp message_for(:unauthorized), do: "You do not have permission to manage members."
  defp message_for(:owner_required), do: "Only an owner can add or change another owner."

  defp message_for(:last_owner),
    do: "This is the only owner left. Promote somebody else first."

  defp message_for(%Ecto.Changeset{} = changeset) do
    cond do
      changeset.errors[:organization_id] || changeset.errors[:user_id] ->
        "That person is already a member of this organization."

      changeset.errors[:email] ->
        "That email address does not look right."

      true ->
        "That change could not be saved."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      organizations={@organizations}
      current_path={@current_path}
      open_incident_count={@open_incident_count}
    >
      <.page_header title="Members">
        <:subtitle>
          Everyone with access to {@current_scope.organization.name}.
        </:subtitle>
      </.page_header>

      <.card :if={@can_manage?} class="mb-6">
        <.form
          for={@form}
          id="add-member-form"
          phx-change="preview"
          phx-submit="add"
          class="flex flex-col gap-3 sm:flex-row sm:items-end"
        >
          <div class="flex-1">
            <.input
              name="member[email]"
              value={@form[:email].value}
              type="email"
              label="Add or invite somebody"
              placeholder="colleague@example.com"
              phx-debounce="300"
              aria-describedby="recipient-hint"
              required
            />
          </div>

          <div class="sm:w-44">
            <.input
              name="member[role]"
              value={@form[:role].value}
              type="select"
              label="Role"
              options={
                Enum.map(assignable_roles(@current_scope), &{String.capitalize(to_string(&1)), &1})
              }
            />
          </div>

          <.button id="add-member-button" variant="primary" disabled={@recipient == :member}>
            <.icon
              name={if(@recipient in [:new, :invited], do: "lucide-mail", else: "lucide-user-plus")}
              class="size-4"
            />
            {submit_label(@recipient)}
          </.button>
        </.form>

        <p
          id="recipient-hint"
          aria-live="polite"
          class={[
            "mt-2 text-xs",
            if(@recipient == :member, do: "text-error", else: "text-base-content/60")
          ]}
        >
          {recipient_hint(@recipient, @current_scope)}
        </p>
      </.card>

      <.card :if={@invitations != []} class="mb-6" padded={false}>
        <p class="px-4 pt-4 text-sm font-medium">Waiting to be accepted</p>

        <ul class="mt-2 divide-y divide-base-300">
          <li
            :for={invitation <- @invitations}
            class="flex flex-wrap items-center gap-3 px-4 py-3"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm">{invitation.email}</p>
              <p class="text-xs text-base-content/50">
                Invited as {invitation.role}, expires {Calendar.strftime(
                  invitation.expires_at,
                  "%Y-%m-%d"
                )}
              </p>
            </div>

            <.button
              :if={@can_manage?}
              phx-click="withdraw"
              phx-value-id={invitation.id}
              variant="ghost"
              size="sm"
            >
              Withdraw
            </.button>
          </li>
        </ul>
      </.card>

      <.card padded={false}>
        <ul class="divide-y divide-base-300">
          <li
            :for={member <- @members}
            class="flex flex-wrap items-center gap-3 px-4 py-3"
            id={"member-#{member.id}"}
          >
            <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-base-200 text-sm font-semibold uppercase">
              {String.first(member.user.email)}
            </span>

            <div class="min-w-0 flex-1">
              <div class="truncate text-sm font-medium">{member.user.email}</div>
              <div class="text-xs text-base-content/50">
                Joined {Calendar.strftime(member.inserted_at, "%d %b %Y")}
                <span :if={member.user_id == @current_scope.user.id}>· you</span>
              </div>
            </div>

            <%= if @can_manage? do %>
              <.tooltip
                id={"member-#{member.id}-locked"}
                text={locked_reason(@current_scope, member) || ""}
                active={not editable?(@current_scope, member)}
                class="inline-flex items-center gap-3"
              >
                <form id={"role-form-#{member.id}"} phx-change="set_role" class="contents">
                  <input type="hidden" name="member_id" value={member.id} />
                  <select
                    name="role"
                    class="select select-bordered select-sm w-32"
                    disabled={not editable?(@current_scope, member)}
                    aria-describedby={
                      not editable?(@current_scope, member) && "member-#{member.id}-locked"
                    }
                  >
                    <option
                      :for={role <- assignable_roles(@current_scope)}
                      value={role}
                      selected={role == member.role}
                    >
                      {String.capitalize(to_string(role))}
                    </option>
                    <%!-- An admin cannot assign the owner role, but must still see
                        it when looking at an owner. --%>
                    <option
                      :if={member.role == :owner and @current_scope.role != :owner}
                      value="owner"
                      selected
                    >
                      Owner
                    </option>
                  </select>
                </form>

                <.button
                  phx-click="remove"
                  phx-value-id={member.id}
                  data-confirm={"Remove #{member.user.email} from #{@current_scope.organization.name}?"}
                  data-confirm-label="Remove member"
                  disabled={not editable?(@current_scope, member)}
                  variant="danger-ghost"
                  size="sm"
                  class="disabled:text-base-content/30"
                  aria-label={"Remove #{member.user.email}"}
                  aria-describedby={
                    not editable?(@current_scope, member) && "member-#{member.id}-locked"
                  }
                >
                  <.icon name="lucide-trash" class="size-4" />
                </.button>
              </.tooltip>
            <% else %>
              <.role_badge role={member.role} />
            <% end %>
          </li>
        </ul>
      </.card>

      <%!-- Reference, not something to act on, so it is folded until wanted. Ignored
            by LiveView patches, which would otherwise close it on every change. --%>
      <details
        id="role-permissions"
        phx-update="ignore"
        class="group mt-8 rounded-box border border-base-300 bg-base-100"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium [&::-webkit-details-marker]:hidden">
          What each role can do
          <.icon
            name="lucide-chevron-down"
            class="size-4 shrink-0 text-base-content/50 transition-transform group-open:rotate-180"
          />
        </summary>

        <div class="overflow-x-auto border-t border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Role</th>
                <th>View</th>
                <th>Respond to incidents</th>
                <th>Manage services</th>
                <th>Manage members</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={role <- Membership.roles()}>
                <td><.role_badge role={role} /></td>
                <td><.permission_mark allowed={permitted?(role, :view)} /></td>
                <td><.permission_mark allowed={permitted?(role, :respond_to_incidents)} /></td>
                <td><.permission_mark allowed={permitted?(role, :manage_services)} /></td>
                <td><.permission_mark allowed={permitted?(role, :manage_organization)} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </Layouts.app>
    """
  end

  # Reads straight from the context, so the table cannot drift away from what is
  # actually enforced.
  defp permitted?(role, action) do
    Organizations.can?(%PulseOps.Accounts.Scope{role: role}, action)
  end

  defp assignable_roles(%{role: :owner}), do: Membership.roles()
  defp assignable_roles(_scope), do: Membership.roles() -- [:owner]

  # You cannot edit yourself out of the organization by accident, and an admin
  # cannot touch an owner. Each rule carries the sentence that explains it, so a
  # locked control always says why.
  defp locked_reason(scope, member) do
    cond do
      member.user_id == scope.user.id ->
        "You cannot change your own role or remove yourself; somebody else who manages members can."

      member.role == :owner and scope.role != :owner ->
        "Only an owner can change or remove another owner."

      true ->
        nil
    end
  end

  defp editable?(scope, member), do: is_nil(locked_reason(scope, member))

  defp recipient(socket, email) do
    address = Invitation.normalize_email(email || "")

    cond do
      not String.contains?(address, "@") -> nil
      Enum.any?(socket.assigns.members, &(&1.user.email == address)) -> :member
      Enum.any?(socket.assigns.invitations, &(&1.email == address)) -> :invited
      PulseOps.Accounts.get_user_by_email(address) -> :account
      true -> :new
    end
  end

  defp submit_label(:account), do: "Add member"
  defp submit_label(recipient) when recipient in [:new, :invited], do: "Send invitation"
  defp submit_label(_recipient), do: "Add or invite"

  defp recipient_hint(:member, scope),
    do: "Already a member of #{scope.organization.name}."

  defp recipient_hint(:invited, _scope),
    do: "Already invited. Sending again replaces the link they were sent."

  defp recipient_hint(:account, _scope),
    do: "They have a PulseOps account, so they are added straight away."

  defp recipient_hint(:new, _scope),
    do:
      "No PulseOps account yet, so they are emailed an invitation that lasts #{Invitation.validity_days()} days."

  defp recipient_hint(nil, _scope),
    do:
      "Somebody with a PulseOps account is added straight away; anybody else is emailed an invitation that lasts #{Invitation.validity_days()} days."
end
