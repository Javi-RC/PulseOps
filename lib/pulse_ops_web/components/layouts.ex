defmodule PulseOpsWeb.Layouts do
  @moduledoc """
  Application shells.

  `app/1` is the signed-in shell: a persistent sidebar with the organization
  switcher, the section navigation and the user menu. `public/1` is the shell for
  the landing page and the authentication screens, which have no organization
  and no navigation to show.
  """
  use PulseOpsWeb, :html

  alias PulseOps.Organizations

  embed_templates "layouts/*"

  @doc """
  The signed-in application shell.

  Below `lg` the sidebar becomes a drawer opened from a top bar, so the whole
  thing works on a phone without any JavaScript of ours.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :organizations, :list, default: [], doc: "organizations the user belongs to"
  attr :current_path, :string, default: nil, doc: "used to mark the active nav item"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="app-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex min-h-screen flex-col">
        <header class="sticky top-0 z-20 flex items-center gap-3 border-b border-base-300 bg-base-100 px-4 py-2 lg:hidden">
          <label for="app-drawer" class="btn btn-ghost btn-sm" aria-label="Open navigation">
            <.icon name="lucide-menu" class="size-5" />
          </label>
          <.brand_mark scope={@current_scope} />
        </header>

        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
          <div class="mx-auto w-full max-w-6xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="app-drawer" class="drawer-overlay" aria-label="Close navigation"></label>

        <aside class="flex h-full w-64 flex-col border-r border-base-300 bg-base-100">
          <div class="px-4 py-4">
            <.brand_mark scope={@current_scope} />
          </div>

          <div :if={organization_scope?(@current_scope)} class="px-3">
            <.org_switcher current_scope={@current_scope} organizations={@organizations} />
          </div>

          <nav :if={organization_scope?(@current_scope)} class="mt-4 flex-1 overflow-y-auto px-3">
            <ul class="space-y-0.5">
              <.nav_item
                :for={item <- nav_items(@current_scope)}
                label={item.label}
                icon={item.icon}
                href={item.href}
                active={active?(@current_path, item.href, item.match)}
              />
            </ul>
          </nav>

          <div class="mt-auto space-y-3 border-t border-base-300 p-3">
            <.theme_toggle />
            <.user_menu :if={@current_scope && @current_scope.user} scope={@current_scope} />
          </div>
        </aside>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The shell for pages that have no organization behind them: the landing page
  and the authentication screens.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :centered, :boolean, default: false, doc: "centre the content, for auth forms"

  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-base-200">
      <header class="border-b border-base-300 bg-base-100">
        <div class="mx-auto flex w-full max-w-5xl items-center justify-between px-4 py-3 sm:px-6">
          <.link navigate={~p"/"} class="flex items-center gap-2 font-semibold">
            <.icon name="lucide-activity" class="size-5 text-primary" /> PulseOps
          </.link>

          <div class="flex items-center gap-2">
            <div class="w-28"><.theme_toggle /></div>
            <%= if @current_scope && @current_scope.user do %>
              <.link navigate={~p"/"} class="btn btn-primary btn-sm">Dashboard</.link>
            <% else %>
              <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
              <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">
                Get started
              </.link>
            <% end %>
          </div>
        </div>
      </header>

      <main class={[
        "flex-1 px-4 py-10 sm:px-6",
        @centered && "flex items-center justify-center"
      ]}>
        <div class={["mx-auto w-full", (@centered && "max-w-sm") || "max-w-5xl"]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer class="border-t border-base-300 px-4 py-4 text-center text-xs text-base-content/50">
        Built with Elixir, Phoenix LiveView and OTP.
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The product name, linking back to wherever "home" is for this visitor.
  """
  attr :scope, :map, default: nil

  def brand_mark(assigns) do
    ~H"""
    <.link navigate={home_path(@scope)} class="flex w-fit items-center gap-2">
      <span class="flex size-7 items-center justify-center rounded-lg bg-primary text-primary-content">
        <.icon name="lucide-activity" class="size-4" />
      </span>
      <span class="font-semibold tracking-tight">PulseOps</span>
    </.link>
    """
  end

  @doc """
  Switches between the organizations the user belongs to.
  """
  attr :current_scope, :map, required: true
  attr :organizations, :list, default: []

  def org_switcher(assigns) do
    ~H"""
    <div class="dropdown w-full">
      <div
        tabindex="0"
        role="button"
        class="flex w-full items-center gap-2 rounded-lg border border-base-300 px-2.5 py-2 text-left hover:bg-base-200"
      >
        <span class="flex size-6 shrink-0 items-center justify-center rounded bg-base-300 text-xs font-semibold uppercase">
          {String.first(@current_scope.organization.name)}
        </span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-sm font-medium">
            {@current_scope.organization.name}
          </span>
          <span class="block text-xs capitalize text-base-content/50">{@current_scope.role}</span>
        </span>
        <.icon name="lucide-chevrons-up-down" class="size-4 shrink-0 text-base-content/40" />
      </div>

      <ul
        tabindex="0"
        class="dropdown-content menu z-50 mt-1 w-60 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
      >
        <li class="menu-title text-xs">Organizations</li>
        <li :for={organization <- @organizations}>
          <.link
            navigate={~p"/orgs/#{organization.slug}"}
            class={organization.id == @current_scope.organization.id && "active"}
          >
            <span class="truncate">{organization.name}</span>
            <.icon
              :if={organization.id == @current_scope.organization.id}
              name="lucide-check"
              class="size-4"
            />
          </.link>
        </li>
        <li class="mt-1 border-t border-base-300 pt-1">
          <.link navigate={~p"/orgs/new"}>
            <.icon name="lucide-plus" class="size-4" /> New organization
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  The signed-in user, with the account and log-out actions.
  """
  attr :scope, :map, required: true

  def user_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-top w-full">
      <div
        tabindex="0"
        role="button"
        class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left hover:bg-base-200"
      >
        <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300 text-xs font-semibold uppercase">
          {String.first(@scope.user.email)}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm">{@scope.user.email}</span>
        <.icon name="lucide-ellipsis-vertical" class="size-4 shrink-0 text-base-content/40" />
      </div>

      <ul
        tabindex="0"
        class="dropdown-content menu z-50 mb-1 w-56 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
      >
        <li>
          <.link navigate={~p"/users/settings"}>
            <.icon name="lucide-user-cog" class="size-4" /> Account settings
          </.link>
        </li>
        <li>
          <.link href={~p"/users/log-out"} method="delete">
            <.icon name="lucide-log-out" class="size-4" /> Log out
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  One entry in the sidebar navigation.
  """
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false

  def nav_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@href}
        aria-current={@active && "page"}
        class={[
          "flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm transition-colors",
          @active && "bg-primary/10 font-medium text-primary",
          !@active && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        ]}
      >
        <.icon name={@icon} class="size-4 shrink-0" />
        {@label}
      </.link>
    </li>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex w-full flex-row items-center rounded-lg border border-base-300 bg-base-200 p-0.5">
      <div class="absolute h-[calc(100%-4px)] w-[calc(33.333%-3px)] rounded-md bg-base-100 shadow-sm transition-[left] left-0.5 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-[66.3%] [[data-theme-source=system]_&]:!left-0.5" />

      <button
        class="z-10 flex w-1/3 cursor-pointer justify-center p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="lucide-monitor" class="size-4 opacity-70 hover:opacity-100" />
      </button>

      <button
        class="z-10 flex w-1/3 cursor-pointer justify-center p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="lucide-sun" class="size-4 opacity-70 hover:opacity-100" />
      </button>

      <button
        class="z-10 flex w-1/3 cursor-pointer justify-center p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="lucide-moon" class="size-4 opacity-70 hover:opacity-100" />
      </button>
    </div>
    """
  end

  # Everything below is a plain helper, not a component. It has to stay after the
  # last component definition: `attr` and `slot` attach to the next function
  # defined, so a helper in between silently steals them.

  defp nav_items(scope) do
    slug = scope.organization.slug

    base = [
      %{
        label: "Dashboard",
        icon: "lucide-layout-dashboard",
        href: ~p"/orgs/#{slug}",
        match: :exact
      },
      %{
        label: "Services",
        icon: "lucide-server",
        href: ~p"/orgs/#{slug}/services",
        match: :prefix
      },
      %{
        label: "Incidents",
        icon: "lucide-siren",
        href: ~p"/orgs/#{slug}/incidents",
        match: :prefix
      },
      %{
        label: "Maintenance",
        icon: "lucide-calendar-clock",
        href: ~p"/orgs/#{slug}/maintenance",
        match: :prefix
      },
      %{label: "Members", icon: "lucide-users", href: ~p"/orgs/#{slug}/members", match: :prefix}
    ]

    if Organizations.can?(scope, :manage_organization) do
      base ++
        [
          %{
            label: "Settings",
            icon: "lucide-settings",
            href: ~p"/orgs/#{slug}/settings",
            match: :prefix
          }
        ]
    else
      base
    end
  end

  # The dashboard lives at the organization root, so as a prefix it would match
  # every other section; it is the one item compared exactly.
  defp active?(nil, _href, _match), do: false
  defp active?(current, href, :exact), do: current == href
  defp active?(current, href, :prefix), do: String.starts_with?(current, href)

  defp organization_scope?(%{organization: %{slug: slug}}) when is_binary(slug), do: true
  defp organization_scope?(_scope), do: false

  defp home_path(scope) do
    if organization_scope?(scope), do: ~p"/orgs/#{scope.organization.slug}", else: ~p"/"
  end
end
