defmodule ForemanWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :foreman

  # Signed and encrypted. Secure-only in production, where the control
  # plane is served over HTTPS (tailscale serve).
  @session_options [
    store: :cookie,
    key: "_foreman_key",
    signing_salt: "oxz9an9c",
    encryption_salt: "ZqJ3p1fU",
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:foreman, :secure_cookies, false),
    max_age: 30 * 24 * 60 * 60
  ]

  def session_options, do: @session_options

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Agents dial in here. They aren't browsers, so there's no origin to
  # check: each connect is authenticated by a signed header instead, and
  # carries no cookies a cross-site page could ride on.
  # sobelow_skip ["Config.CSWH"]
  socket "/agent", ForemanWeb.AgentSocket,
    websocket: [connect_info: [:x_headers, :peer_data], check_origin: false, timeout: 60_000],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :foreman,
    gzip: not code_reloading?,
    only: ForemanWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :foreman
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 2_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ForemanWeb.Router
end
