defmodule PulseOpsWeb.UIComponents do
  @moduledoc """
  The building blocks the application screens are assembled from: page headers,
  cards, empty states and the small badges that repeat everywhere.

  Anything that carries monitoring meaning — service status, incident severity,
  the latency chart — lives in `PulseOpsWeb.MonitoringComponents` instead. This
  module is plain furniture.
  """

  use Phoenix.Component

  import PulseOpsWeb.CoreComponents, only: [icon: 1]

  @doc """
  The heading of a page: title, optional explanation, optional actions.
  """
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class={["mb-6 flex flex-wrap items-start justify-between gap-4", @class]}>
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-base-content/60">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-none items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  A bordered surface. `padded={false}` for cards whose content draws its own
  edges, such as a full-bleed list.
  """
  attr :class, :string, default: nil
  attr :padded, :boolean, default: true
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class={[
        "rounded-box border border-base-300 bg-base-100",
        @padded && "p-4 sm:p-5",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  What a list shows when it has nothing in it: says why it is empty and offers
  the one action that fixes that.
  """
  attr :icon, :string, default: "lucide-inbox"
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :subtitle
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "rounded-box border border-dashed border-base-300 px-6 py-12 text-center",
      @class
    ]}>
      <span class="mx-auto flex size-11 items-center justify-center rounded-full bg-base-200 text-base-content/40">
        <.icon name={@icon} class="size-5" />
      </span>
      <p class="mt-3 font-medium">{@title}</p>
      <p :if={@subtitle != []} class="mx-auto mt-1 max-w-sm text-sm text-base-content/60">
        {render_slot(@subtitle)}
      </p>
      <div :if={@actions != []} class="mt-4 flex justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  A member's role.
  """
  attr :role, :atom, required: true

  def role_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium capitalize",
      role_class(@role)
    ]}>
      {@role}
    </span>
    """
  end

  @doc """
  A yes/no cell in the permission table. Never a bare colour: the icon carries it.
  """
  attr :allowed, :boolean, required: true

  def permission_mark(assigns) do
    ~H"""
    <span class={["inline-flex", (@allowed && "text-success") || "text-base-content/25"]}>
      <.icon name={(@allowed && "lucide-check") || "lucide-minus"} class="size-4" />
      <span class="sr-only">{(@allowed && "allowed") || "not allowed"}</span>
    </span>
    """
  end

  @doc """
  A row of filter controls above the thing they scope.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def filter_bar(assigns) do
    ~H"""
    <div class={["mb-4 flex flex-wrap items-center gap-2", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One toggle inside a `filter_bar`.
  """
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-key phx-value-value)

  def filter_chip(assigns) do
    ~H"""
    <button
      type="button"
      aria-pressed={to_string(@active)}
      class={[
        "rounded-full border px-3 py-1 text-sm transition-colors",
        @active && "border-primary bg-primary/10 font-medium text-primary",
        !@active && "border-base-300 text-base-content/70 hover:bg-base-200"
      ]}
      {@rest}
    >
      {@label}
    </button>
    """
  end

  # Owner and admin get weight; the read-only roles stay quiet. None of these
  # reuse a status colour — those are reserved for whether a service is up.
  defp role_class(:owner), do: "bg-primary/10 text-primary"
  defp role_class(:admin), do: "bg-base-300 text-base-content"
  defp role_class(_role), do: "bg-base-200 text-base-content/60"
end
