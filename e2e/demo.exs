# A control plane full of made-up data, for the README screenshots: three
# boxes held online by stand-in agents, a few repos, and environments in
# different states. It uses its own database (tmp/demo) and leaves the dev
# one alone. Nothing runs: no Docker, no GitHub, no tailnet.
#
#   cd apps/foreman && PORT=4100 mix run --no-start ../../e2e/demo.exs
#   node e2e/screenshots.mjs              (from the repo root, in another shell)
alias Foreman.{Accounts, Operations, Repo, Repos, Scope, Secrets}
alias Foreman.Boxes.Box
alias Foreman.Capacity.Tracker
alias Foreman.Environments.Environment
import Ecto.Query

root = Path.expand("../tmp/demo", __DIR__)
File.rm_rf!(root)
File.mkdir_p!(root)

Application.load(:foreman)

Application.put_env(
  :foreman,
  Repo,
  Keyword.put(Application.get_env(:foreman, Repo), :database, Path.join(root, "foreman.db"))
)

Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
# Only so the UI shows the tailnet SSH command; nothing calls Tailscale.
Application.put_env(:foreman, :tailscale, %{
  client_id: "demo",
  client_secret: "demo",
  tailnet: "demo"
})

Application.put_env(
  :foreman,
  Oban,
  Keyword.merge(Application.get_env(:foreman, Oban), plugins: false, queues: false)
)

{:ok, _, _} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))
Logger.configure(level: :info)
{:ok, _} = Application.ensure_all_started(:foreman)

now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -minutes * 60) end

user = fn login, name, email ->
  {:ok, user} =
    Accounts.sign_in_from_github(
      %{"id" => :erlang.phash2(login), "login" => login, "name" => name, "avatar_url" => nil},
      %{access_token: nil, refresh_token: nil},
      config: %{admins: ["mona"], allowed_users: ["mona", "jordan", "sam"], allowed_org: nil}
    )

  {:ok, user} =
    Accounts.update_preferences(Scope.for_user(user), %{"git_name" => name, "git_email" => email})

  user
end

mona = user.("mona", "Mona", "mona@acme.dev")
jordan = user.("jordan", "Jordan", "jordan@acme.dev")
sam = user.("sam", "Sam", "sam@acme.dev")
admin = Scope.for_user(mona)

repo = fn name, reqs ->
  {:ok, repo} =
    Repos.add_repo(admin, "acme/#{name}", %{
      devcontainer_path: ".devcontainer/devcontainer.json",
      host_requirements: reqs
    })

  repo
end

storefront = repo.("storefront", %{"cpus" => 4, "memory" => "8gb"})
api = repo.("api", %{"cpus" => 2, "memory" => "4gb"})
docs = repo.("docs", %{"cpus" => 1, "memory" => "2gb"})
_mobile = repo.("mobile", %{"cpus" => 4, "memory" => "8gb"})
owner = Repos.get_owner_by_login("acme")

for {scope_name, subject, name, value} <- [
      {"owner", owner, "SENTRY_DSN", "https://demo@sentry.example/1"},
      {"owner", owner, "NPM_TOKEN", "npm_demo"},
      {"repo", storefront, "STRIPE_SECRET_KEY", "sk_test_demo"},
      {"repo", storefront, "DATABASE_URL", "postgres://postgres@db/storefront"},
      {"repo", api, "DATABASE_URL", "postgres://postgres@db/api"},
      {"user", mona, "OPENAI_API_KEY", "demo"},
      {"user", mona, "AWS_PROFILE", "dev"}
    ] do
  {:ok, _} = Secrets.put_secret(admin, scope_name, subject, %{"name" => name, "value" => value})
end

box = fn name, owner_user, hostname, arch, cpus, memory_gb, disk_gb, free_gb ->
  Repo.insert!(%Box{
    name: name,
    owner_user_id: owner_user.id,
    shared_user_ids: [],
    public_key: :crypto.strong_rand_bytes(32),
    agent_version: "0.1.0",
    protocol_version: 1,
    hostname: hostname,
    os: "linux",
    arch: arch,
    capacity: %{
      "cpus" => cpus,
      "memory_mb" => memory_gb * 1024,
      "disk_mb" => disk_gb * 1024,
      "disk_free_mb" => free_gb * 1024
    },
    last_seen_at: now
  })
end

desktop = box.("desktop", mona, "mona-desktop", "x86_64", 16, 64, 1800, 1210)
box_a = box.("box-a", jordan, "box-a", "x86_64", 8, 32, 450, 290)
box_b = box.("box-b", sam, "box-b", "aarch64", 8, 32, 450, 310)

env = fn repo, index, owner_user, box, branch, state, minutes, extra ->
  services = Map.get(extra, :services, ["app", "db"])

  Repo.insert!(
    struct!(
      Environment,
      Map.merge(
        %{
          slug: "#{repo.name}-#{index}",
          index: index,
          repo_id: repo.id,
          user_id: owner_user.id,
          box_id: box.id,
          branch: branch,
          desired_state: if(state == "stopped", do: "stopped", else: "running"),
          observed_state: state,
          remote_user: "vscode",
          workspace_folder: "/workspaces/#{repo.name}",
          services: services,
          devcontainer_service: "app",
          created_once: true,
          inserted_at: ago.(minutes),
          updated_at: ago.(div(minutes, 3))
        },
        Map.delete(extra, :services)
      )
    )
  )
end

sf1 =
  env.(storefront, 1, mona, desktop, "main", "running", 60 * 26, %{
    services: ["app", "db", "redis", "worker"]
  })

sf2 =
  env.(storefront, 2, mona, desktop, "checkout-redesign", "running", 95, %{
    services: ["app", "db", "redis", "worker"],
    pending_restart: true,
    pending_changes: ["STRIPE_SECRET_KEY"]
  })

api1 = env.(api, 1, mona, desktop, "main", "running", 60 * 50, %{})
docs1 = env.(docs, 1, mona, desktop, "main", "stopped", 60 * 72, %{services: ["app"]})
_api2 = env.(api, 2, jordan, box_a, "rate-limits", "running", 60 * 5, %{})

_sf3 =
  env.(storefront, 3, jordan, box_a, "search", "creating", 2, %{
    services: ["app", "db", "redis", "worker"],
    remote_user: nil
  })

_api3 = env.(api, 3, sam, box_b, "main", "running", 60 * 30, %{})

build_log = fn env ->
  containers =
    for step <- ~w(Creating Created Starting Started),
        service <- env.services,
        do: " Container #{env.slug}-#{service}-1 #{step}\n"

  """
  #1 [internal] load build definition from Dockerfile
  #1 transferring dockerfile: 1.21kB done
  #1 DONE 0.0s

  #2 [internal] load metadata for mcr.microsoft.com/devcontainers/base:bookworm
  #2 DONE 0.6s

  #9 [dev_containers_target_stage 4/4] RUN ./devcontainer-features-install.sh
  #9 2.981 foreman: installed Tailscale 1.104.1 (amd64)
  #9 3.004 foreman: feature installed
  #9 DONE 3.4s

  #15 exporting to image
  #15 naming to docker.io/library/vsc-#{env.slug}-1f0c2a9b:latest done
  #15 DONE 0.4s
   Image vsc-#{env.slug}-1f0c2a9b Built
   Network #{env.slug}_default Creating
   Network #{env.slug}_default Created
  #{containers}Running the postCreateCommand from devcontainer.json...
  bin/setup
  == Installing dependencies ==
  == Preparing database ==
  == Done ==
  Running the postStartCommand from devcontainer.json...
  """
end

op = fn env, action, status, minutes, secs, log ->
  Operations.create!(%{
    id: Ecto.UUID.generate(),
    environment_id: env.id,
    box_id: env.box_id,
    user_id: env.user_id,
    action: action,
    command: action,
    status: status,
    log: log,
    dispatched_at: ago.(minutes),
    started_at: ago.(minutes),
    finished_at: DateTime.add(ago.(minutes), secs),
    inserted_at: ago.(minutes),
    updated_at: DateTime.add(ago.(minutes), secs)
  })
end

for e <- [sf1, api1, docs1] do
  op.(e, "create", "succeeded", div(DateTime.diff(now, e.inserted_at), 60), 74, build_log.(e))
end

op.(
  docs1,
  "stop",
  "succeeded",
  60 * 20,
  3,
  " Container docs-1-app-1 Stopping\n Container docs-1-app-1 Stopped\n"
)

op.(sf2, "create", "succeeded", 95, 81, build_log.(sf2))

# Stand-in agents: registered like a connected agent's channel process, so
# the boxes show as online. They drop whatever is sent to them.
for b <- [desktop, box_a, box_b] do
  spawn(fn ->
    Foreman.Agents.register(b.id)
    Stream.repeatedly(fn -> receive do: (_ -> :ok) end) |> Stream.run()
  end)
end

usage = %{
  sf1.id => %{cpu_percent: 212.0, memory_mb: 5_420},
  sf2.id => %{cpu_percent: 148.0, memory_mb: 4_870},
  api1.id => %{cpu_percent: 64.0, memory_mb: 2_310}
}

Tracker.record(desktop.id, %{capacity: desktop.capacity, environments: usage})

for {b, envs} <- [
      {box_a, %{cpu_percent: 230.0, memory_mb: 6_900}},
      {box_b, %{cpu_percent: 41.0, memory_mb: 1_820}}
    ] do
  live =
    Repo.all(from(e in Environment, where: e.box_id == ^b.id and e.observed_state == "running"))

  Tracker.record(b.id, %{capacity: b.capacity, environments: Map.new(live, &{&1.id, envs})})
end

port = System.get_env("PORT", "4000")
IO.puts("demo control plane on http://localhost:#{port}, sign in at /dev/sign-in/mona")
IO.puts("DEMO_ENV_PENDING=/environments/#{sf2.id}")
IO.puts("DEMO_ENV_RUNNING=/environments/#{sf1.id}")
IO.puts("DEMO_BOX=/boxes/#{desktop.id}")
IO.puts("DEMO_REPO=/repos/#{storefront.id}")
Process.sleep(:infinity)
