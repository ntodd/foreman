defmodule Foreman.Fixtures do
  @moduledoc "Builds records for tests."

  alias Foreman.Repo

  def unique, do: System.unique_integer([:positive])

  def user_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    n = unique()

    %Foreman.Accounts.User{
      login: Map.get(attrs, :login, "user#{n}"),
      github_id: Map.get(attrs, :github_id, n),
      name: Map.get(attrs, :name, "User #{n}"),
      role: Map.get(attrs, :role, "member"),
      access_token: Map.get(attrs, :access_token, "ghu_user#{n}"),
      access_token_expires_at:
        Map.get(attrs, :access_token_expires_at, DateTime.add(DateTime.utc_now(), 8 * 3600)),
      refresh_token: Map.get(attrs, :refresh_token, "ghr_user#{n}"),
      refresh_token_expires_at: DateTime.add(DateTime.utc_now(), 86_400 * 180),
      git_name: Map.get(attrs, :git_name),
      git_email: Map.get(attrs, :git_email),
      disabled_at: Map.get(attrs, :disabled_at)
    }
    |> Repo.insert!()
  end

  def owner_fixture(attrs \\ []) do
    attrs = Map.new(attrs)

    %Foreman.Repos.Owner{
      login: Map.get(attrs, :login, "owner#{unique()}"),
      kind: Map.get(attrs, :kind, "User"),
      installation_id: Map.get(attrs, :installation_id, unique())
    }
    |> Repo.insert!()
  end

  def repo_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    owner = Map.get_lazy(attrs, :owner, fn -> owner_fixture() end)
    name = Map.get(attrs, :name, "repo#{unique()}")

    %Foreman.Repos.Repo{
      owner_id: owner.id,
      full_name: "#{owner.login}/#{name}",
      name: name,
      default_branch: "main",
      devcontainer_path: Map.get(attrs, :devcontainer_path, ".devcontainer/devcontainer.json"),
      host_requirements: Map.get(attrs, :host_requirements),
      token_mode: Map.get(attrs, :token_mode, "scoped"),
      tailscale_tags: Map.get(attrs, :tailscale_tags, []),
      cpu_limit: Map.get(attrs, :cpu_limit),
      memory_limit_mb: Map.get(attrs, :memory_limit_mb)
    }
    |> Repo.insert!()
    |> Repo.preload(:owner)
  end

  def box_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    {public, private} = ForemanProtocol.Auth.generate_keypair()

    box =
      %Foreman.Boxes.Box{
        name: Map.get(attrs, :name, "box#{unique()}"),
        owner_user_id: Map.get(attrs, :owner_user_id),
        public_key: public,
        capacity:
          Map.get(attrs, :capacity, %{
            "cpus" => 16,
            "memory_mb" => 65_536,
            "disk_mb" => 1_000_000,
            "disk_free_mb" => 500_000
          }),
        capacity_policy: Map.get(attrs, :capacity_policy, "allow"),
        policy: Map.get(attrs, :policy, ForemanProtocol.Policy.defaults()),
        agent_version: "0.1.0",
        protocol_version: 1
      }
      |> Repo.insert!()

    Map.put(box, :__private_key__, private)
  end

  def environment_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    user = Map.get_lazy(attrs, :user, fn -> user_fixture() end)
    repo = Map.get_lazy(attrs, :repo, fn -> repo_fixture() end)
    box = Map.get_lazy(attrs, :box, fn -> box_fixture(owner_user_id: user.id) end)
    n = unique()

    %Foreman.Environments.Environment{
      slug: Map.get(attrs, :slug, "#{repo.name}-#{n}"),
      index: n,
      repo_id: repo.id,
      user_id: user.id,
      box_id: box.id,
      branch: Map.get(attrs, :branch, "main"),
      desired_state: Map.get(attrs, :desired_state, "running"),
      observed_state: Map.get(attrs, :observed_state, "running"),
      created_once: Map.get(attrs, :created_once, true),
      devcontainer_service: "app",
      services: ["app", "db"]
    }
    |> Repo.insert!()
  end

  def secret_fixture(scope, subject, name, value, attrs \\ []) do
    {:ok, secret} =
      Foreman.Secrets.put_secret(
        Foreman.Scope.for_user(Keyword.get(attrs, :actor) || user_fixture(role: "admin")),
        scope,
        subject,
        %{"name" => name, "value" => value, "repo_ids" => Keyword.get(attrs, :repo_ids, [])}
      )

    secret
  end
end
