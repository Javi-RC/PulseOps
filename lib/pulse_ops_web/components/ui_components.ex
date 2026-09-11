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

  alias Phoenix.LiveView.JS

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
  attr :rest, :global
  slot :subtitle
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div
      class={[
        "rounded-box border border-dashed border-base-300 px-6 py-12 text-center",
        @class
      ]}
      {@rest}
    >
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
  A card holding a list, one row per item with a hairline between rows — the
  shape most index pages take. The rows share their padding; `class` on an item
  lays out what goes inside it.

  ## Examples

      <.list_card id="tokens">
        <:item :for={token <- @tokens} class="flex items-center justify-between gap-3">
          {token.name}
        </:item>
      </.list_card>
  """
  attr :class, :string, default: nil
  attr :rest, :global

  slot :item, required: true do
    attr :class, :string
  end

  def list_card(assigns) do
    ~H"""
    <ul
      class={["divide-y divide-base-300 rounded-box border border-base-300 bg-base-100", @class]}
      {@rest}
    >
      <li :for={item <- @item} class={["p-4 sm:p-5", item[:class]]}>
        {render_slot(item)}
      </li>
    </ul>
    """
  end

  @doc """
  Explains a control on hover and keyboard focus, and to screen readers.

  Mostly for saying why something is disabled: a greyed-out control that does not
  say why reads as broken. The wrapper takes the focus, because a disabled control
  can be neither focused nor reliably hovered; the same text is rendered for
  assistive technology under `id`, for the control's `aria-describedby`.

  With `active={false}` it renders only the wrapper, so a control that is
  sometimes locked keeps one layout either way.

  ## Examples

      <.tooltip id="role-locked-3" text="Only an owner can change another owner.">
        <select disabled aria-describedby="role-locked-3">...</select>
      </.tooltip>
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :active, :boolean, default: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def tooltip(%{active: false} = assigns) do
    ~H"""
    <span class={@class}>{render_slot(@inner_block)}</span>
    """
  end

  def tooltip(assigns) do
    ~H"""
    <span class={["tooltip", @class]} data-tip={@text} tabindex="0">
      {render_slot(@inner_block)}
      <span id={@id} class="sr-only">{@text}</span>
    </span>
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
  A compact heading for grouping content within a page.

  Replaces the duplicated `text-sm font-semibold uppercase tracking-wide text-base-content/60`
  pattern that appeared across the codebase.
  """
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :subtitle
  slot :actions

  def section_heading(assigns) do
    assigns = assign_new(assigns, :inner_block, fn -> [] end)

    ~H"""
    <div class={["mb-3 flex flex-wrap items-end justify-between gap-2", @class]}>
      <div>
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
          <%= if @inner_block == [] do %>
            {@title}
          <% else %>
            {render_slot(@inner_block)}
          <% end %>
        </h2>
        <p :if={@subtitle != []} class="mt-0.5 text-xs text-base-content/50">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Breadcrumb navigation for nested pages.

  ## Examples

      <.breadcrumb>
        <:item navigate={~p"/orgs/acme"}>Acme</:item>
        <:item navigate={~p"/orgs/acme/services"}>Services</:item>
        <:item>Payments API</:item>
      </.breadcrumb>
  """
  slot :item, required: true do
    attr :navigate, :string
    attr :patch, :string
  end

  def breadcrumb(assigns) do
    ~H"""
    <nav class="mb-4 text-sm text-base-content/60" aria-label="Breadcrumb">
      <ol class="flex flex-wrap items-center gap-1">
        <li :for={{item, index} <- Enum.with_index(@item)} class="flex items-center gap-1">
          <span :if={index > 0} class="text-base-content/30">/</span>
          <%= if item[:navigate] || item[:patch] do %>
            <.link
              navigate={item[:navigate]}
              patch={item[:patch]}
              class="hover:text-base-content hover:underline"
            >
              {render_slot(item)}
            </.link>
          <% else %>
            <span class="text-base-content font-medium">{render_slot(item)}</span>
          <% end %>
        </li>
      </ol>
    </nav>
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

  # -------------------------------------------------------------------
  # Modal & confirmation
  # -------------------------------------------------------------------

  @doc """
  A modal dialog. Controlled via the `@show` assign and JS commands.

  ## Examples

      <.modal id="confirm-modal" show={@show_confirm} on_cancel={JS.push("cancel")}>
        <p>Are you sure?</p>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-bg"} class="fixed inset-0 bg-black/50" phx-click={@on_cancel} />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-desc"}
        aria-modal="true"
        role="dialog"
      >
        <div class="flex min-h-full items-center justify-center p-4">
          <div
            id={"#{@id}-container"}
            phx-window-keydown={@on_cancel}
            phx-key="escape"
            phx-click-away={@on_cancel}
            class="relative w-full max-w-lg rounded-box border border-base-300 bg-base-100 p-6 shadow-xl"
          >
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A confirmation dialog for destructive actions.

  ## Examples

      <.confirmation_dialog
        id="delete-service"
        show={@show_delete}
        title="Delete service"
        confirm_label="Delete"
        on_cancel={JS.push("close_delete")}
        on_confirm={JS.push("confirm_delete")}
      >
        <p>This will permanently remove the service and all its data.</p>
      </.confirmation_dialog>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, required: true
  attr :confirm_label, :string, default: "Confirm"
  attr :on_cancel, JS, default: %JS{}
  attr :on_confirm, JS, default: %JS{}

  slot :inner_block, required: true

  def confirmation_dialog(assigns) do
    ~H"""
    <.modal id={@id} show={@show} on_cancel={@on_cancel}>
      <h3 class="text-lg font-semibold" id={"#{@id}-title"}>{@title}</h3>
      <div class="mt-2 text-sm text-base-content/70" id={"#{@id}-desc"}>
        {render_slot(@inner_block)}
      </div>
      <div class="mt-6 flex justify-end gap-3">
        <button type="button" class="btn btn-soft" phx-click={@on_cancel}>
          Cancel
        </button>
        <button type="button" class="btn btn-error" phx-click={@on_confirm}>
          {@confirm_label}
        </button>
      </div>
    </.modal>
    """
  end

  # -------------------------------------------------------------------
  # Skeleton loading states
  # -------------------------------------------------------------------

  @doc """
  A loading skeleton placeholder.

  ## Examples

      <.skeleton class="h-4 w-48" />
      <.skeleton class="h-20 w-full" variant="rounded" />
  """
  attr :class, :string, default: "h-4 w-full"
  attr :variant, :string, values: ~w(rectangular rounded circle), default: "rounded"

  def skeleton(assigns) do
    ~H"""
    <div class={[
      "animate-pulse bg-base-200",
      @variant == "rectangular" && "rounded-none",
      @variant == "rounded" && "rounded",
      @variant == "circle" && "rounded-full",
      @class
    ]} />
    """
  end

  # -------------------------------------------------------------------
  # Badge
  # -------------------------------------------------------------------

  @doc """
  A generic badge for labels, counts, and status indicators.

  ## Examples

      <.badge>Default</.badge>
      <.badge color="success">Up</.badge>
      <.badge color="error" size="lg">P1</.badge>
  """
  attr :color, :string,
    values: ~w(default primary secondary accent neutral success warning error info),
    default: "default"

  attr :size, :string, values: ~w(xs sm md lg), default: "sm"
  attr :variant, :string, values: ~w(filled outline ghost), default: "filled"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center font-medium",
      badge_size(@size),
      badge_variant(@variant, @color),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_size("xs"), do: "px-1.5 py-0.5 text-[10px]"
  defp badge_size("sm"), do: "px-2 py-0.5 text-xs"
  defp badge_size("md"), do: "px-3 py-1 text-sm"
  defp badge_size("lg"), do: "px-4 py-1.5 text-base"

  defp badge_variant("filled", "default"), do: "bg-base-200 text-base-content/80"
  defp badge_variant("filled", "primary"), do: "bg-primary/15 text-primary"
  defp badge_variant("filled", "secondary"), do: "bg-secondary/15 text-secondary"
  defp badge_variant("filled", "accent"), do: "bg-accent/15 text-accent"
  defp badge_variant("filled", "neutral"), do: "bg-base-300 text-base-content"
  defp badge_variant("filled", "success"), do: "bg-success/15 text-success"
  defp badge_variant("filled", "warning"), do: "bg-warning/15 text-warning"
  defp badge_variant("filled", "error"), do: "bg-error/15 text-error"
  defp badge_variant("filled", "info"), do: "bg-info/15 text-info"
  defp badge_variant("outline", color), do: "border border-current/30 " <> badge_text(color)
  defp badge_variant("ghost", color), do: "bg-transparent hover:bg-base-200 " <> badge_text(color)

  # Spelled out rather than built from the colour name: Tailwind only generates
  # the classes it can find written in the source.
  defp badge_text("default"), do: "text-base-content/80"
  defp badge_text("primary"), do: "text-primary"
  defp badge_text("secondary"), do: "text-secondary"
  defp badge_text("accent"), do: "text-accent"
  defp badge_text("neutral"), do: "text-base-content"
  defp badge_text("success"), do: "text-success"
  defp badge_text("warning"), do: "text-warning"
  defp badge_text("error"), do: "text-error"
  defp badge_text("info"), do: "text-info"

  # -------------------------------------------------------------------
  # Tabs
  # -------------------------------------------------------------------

  @doc """
  Tab navigation for switching between views or filters.

  ## Examples

      <.tabs>
        <:tab active={@tab == :all} phx-click="set_tab" phx-value-tab="all">All</:tab>
        <:tab active={@tab == :open} phx-click="set_tab" phx-value-tab="open">Open</:tab>
      </.tabs>
  """
  attr :class, :any, default: nil
  slot :tab, required: true

  def tabs(assigns) do
    ~H"""
    <div
      role="tablist"
      class={[
        "flex gap-1 rounded-box border border-base-300 bg-base-200/50 p-1",
        @class
      ]}
    >
      <button
        :for={tab <- @tab}
        type="button"
        role="tab"
        aria-selected={to_string(tab[:active])}
        class={[
          "flex-1 rounded-sm px-4 py-2 text-sm font-medium transition-all",
          tab[:active] && "bg-base-100 shadow-sm text-base-content",
          !tab[:active] && "text-base-content/60 hover:text-base-content/80"
        ]}
        {drop_rest(tab)}
      >
        {render_slot(tab)}
      </button>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Pagination
  # -------------------------------------------------------------------

  @doc """
  Simple page-based pagination.

  ## Examples

      <.pagination current={@page} total={@total_pages} event="paginate" />
  """
  attr :current, :integer, required: true
  attr :total, :integer, required: true
  attr :event, :string, default: "paginate"
  attr :class, :any, default: nil

  def pagination(assigns) do
    ~H"""
    <nav
      :if={@total > 1}
      class={["flex items-center justify-center gap-1", @class]}
      aria-label="Pagination"
    >
      <button
        type="button"
        disabled={@current <= 1}
        phx-click={@event}
        phx-value-page={@current - 1}
        aria-label="Previous page"
        class="btn btn-sm btn-ghost"
      >
        <.icon name="lucide-chevron-left" class="size-4" />
      </button>

      <%= for page <- pagination_range(@current, @total) do %>
        <%= if page == :gap do %>
          <span class="px-2 text-base-content/40" aria-hidden="true">…</span>
        <% else %>
          <button
            type="button"
            phx-click={@event}
            phx-value-page={page}
            aria-label={"Page #{page}"}
            aria-current={page == @current && "page"}
            class={[
              "btn btn-sm",
              page == @current && "btn-primary",
              page != @current && "btn-ghost"
            ]}
          >
            {page}
          </button>
        <% end %>
      <% end %>

      <button
        type="button"
        disabled={@current >= @total}
        phx-click={@event}
        phx-value-page={@current + 1}
        aria-label="Next page"
        class="btn btn-sm btn-ghost"
      >
        <.icon name="lucide-chevron-right" class="size-4" />
      </button>
    </nav>
    """
  end

  defp pagination_range(_current, total) when total <= 7, do: Enum.to_list(1..total//1)

  # The first and last page and the current one with its neighbours, with a gap
  # only where pages were actually skipped.
  defp pagination_range(current, total) do
    [1, current - 1, current, current + 1, total]
    |> Enum.filter(&(&1 in 1..total))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [page, next] when next - page > 1 -> [page, :gap]
      [page | _rest] -> [page]
    end)
  end

  # -------------------------------------------------------------------
  # Modal JS helpers
  # -------------------------------------------------------------------

  defp show_modal(id) do
    %JS{}
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      transition: {"transition-opacity ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      transition:
        {"transition-all ease-out duration-300", "opacity-0 scale-95", "opacity-100 scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
  end

  defp hide_modal(id) do
    %JS{}
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-opacity ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "##{id}-container",
      transition:
        {"transition-all ease-in duration-200", "opacity-100 scale-100", "opacity-0 scale-95"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
  end

  # A slot entry carries its own bookkeeping and the `active` flag the component
  # reads; none of that belongs on the rendered element.
  defp drop_rest(assigns), do: Map.drop(assigns, [:__changed__, :__slot__, :inner_block, :active])
end
