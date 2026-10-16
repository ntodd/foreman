defmodule ForemanWeb.Router do
  use ForemanWeb, :router

  import ForemanWeb.UserAuth
  import Oban.Web.Router

  # sobelow_skip ["Config.CSP"]
  # The policy is set by ForemanWeb.Plugs.SecurityHeaders, per request.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForemanWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ForemanWeb.Plugs.SecurityHeaders
    plug :fetch_current_scope
  end

  pipeline :signed_in do
    plug :require_user
  end

  pipeline :admin do
    plug :require_user
    plug :require_admin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health checks: no session, no pipeline, and not logged (they come
  # every few seconds).
  scope "/", ForemanWeb do
    get "/healthz", HealthController, :show, log: false
  end

  # Signed-out pages: sign in, and first-run setup.
  scope "/", ForemanWeb do
    pipe_through :browser

    get "/sign-in", AuthController, :new
    get "/auth/github", AuthController, :request
    get "/auth/github/callback", AuthController, :callback
    delete "/sign-out", AuthController, :delete

    get "/setup", SetupController, :show
    post "/setup", SetupController, :verify
    get "/setup/github", SetupController, :github
    get "/setup/github/created", SetupController, :created
    get "/setup/github/installed", SetupController, :installed
  end

  # Agents: enrollment, the install script and release downloads. Release
  # tarballs are signed, and the agent checks the signature itself.
  scope "/", ForemanWeb do
    pipe_through :api

    post "/api/agents/enroll", AgentController, :enroll
    get "/agent/install.sh", AgentController, :install_script
    get "/agent/releases/:version/:target", AgentController, :release
  end

  scope "/", ForemanWeb do
    pipe_through [:browser, :signed_in]

    live_session :signed_in, on_mount: [{ForemanWeb.UserAuth, :require_user}] do
      live "/", EnvironmentLive.Index, :index
      live "/environments/new", EnvironmentLive.New, :new
      live "/environments/:id", EnvironmentLive.Show, :show
      live "/repos", RepoLive.Index, :index
      live "/repos/:id", RepoLive.Show, :show
      live "/boxes", BoxLive.Index, :index
      live "/boxes/:id", BoxLive.Show, :show
      live "/secrets", SecretsLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  scope "/admin", ForemanWeb do
    pipe_through [:browser, :admin]

    live_session :admin,
      on_mount: [{ForemanWeb.UserAuth, :require_user}, {ForemanWeb.UserAuth, :require_admin}] do
      live "/", AdminLive.Deployment, :index
      live "/users", AdminLive.Users, :index
      live "/audit", AdminLive.Audit, :index
    end
  end

  scope "/admin" do
    pipe_through [:browser, :admin]

    oban_dashboard("/oban", resolver: ForemanWeb.ObanResolver)
  end

  if Application.compile_env(:foreman, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ForemanWeb.Telemetry
      get "/sign-in/:login", ForemanWeb.DevAuthController, :create
    end
  end
end
