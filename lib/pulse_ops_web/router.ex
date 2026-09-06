defmodule PulseOpsWeb.Router do
  use PulseOpsWeb, :router

  import PulseOpsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PulseOpsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PulseOpsWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", PulseOpsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pulse_ops, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PulseOpsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # A monitoring target that can be broken on demand, so an incident can be
    # produced end to end without waiting for something real to fail.
    scope "/dev", PulseOpsWeb do
      pipe_through :api

      get "/flaky", FlakyController, :show
      # Deliberately on the api pipeline: the browser pipeline's CSRF protection
      # would reject these, and the dashboard toggles the endpoint through a
      # LiveView event rather than an HTTP post anyway.
      post "/flaky/break", FlakyController, :break
      post "/flaky/heal", FlakyController, :heal
    end
  end

  ## Authentication routes

  scope "/", PulseOpsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PulseOpsWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/orgs/new", OrganizationLive.Form, :new
    end

    # Tenant routes. :require_organization resolves the :org slug, checks
    # membership and narrows current_scope, so every LiveView below it can only
    # reach data belonging to that organization.
    live_session :require_organization,
      on_mount: [{PulseOpsWeb.UserAuth, :require_organization}] do
      live "/orgs/:org", DashboardLive, :index
      live "/orgs/:org/incidents", IncidentLive.Index, :index
      live "/orgs/:org/incidents/:id", IncidentLive.Show, :show
      live "/orgs/:org/services", ServiceLive.Index, :index
      live "/orgs/:org/services/new", ServiceLive.Form, :new
      live "/orgs/:org/services/:id", ServiceLive.Show, :show
      live "/orgs/:org/services/:id/edit", ServiceLive.Form, :edit
      live "/orgs/:org/members", MemberLive.Index, :index
      live "/orgs/:org/settings", OrganizationLive.Settings, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PulseOpsWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PulseOpsWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
