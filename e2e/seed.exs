# Seeds a control plane for end-to-end runs without GitHub: an admin, the
# fixture repo added by hand, and a join token for one box (printed).
#
#   mix run ../../e2e/seed.exs            (from apps/foreman)
#   bin/foreman eval 'Code.eval_file("e2e/seed.exs")'
alias Foreman.{Accounts, Boxes, Repos, Scope}

{:ok, _} = Application.ensure_all_started(:foreman)

login = System.get_env("E2E_ADMIN", "dev")
box_name = System.get_env("E2E_BOX", "local")

{:ok, admin} =
  Accounts.sign_in_from_github(
    %{"id" => :erlang.phash2(login), "login" => login, "name" => String.capitalize(login), "avatar_url" => nil},
    %{access_token: nil, refresh_token: nil},
    config: %{admins: [login], allowed_users: [], allowed_org: nil}
  )

{:ok, admin} =
  Accounts.update_preferences(Scope.for_user(admin), %{"git_name" => "Foreman E2E", "git_email" => "e2e@example.com"})

scope = Scope.for_user(admin)

repo =
  case Repos.get_repo_by_full_name("ntodd/hello") do
    nil ->
      {:ok, repo} = Repos.add_repo(scope, "ntodd/hello", %{devcontainer_path: ".devcontainer/devcontainer.json", host_requirements: %{"cpus" => 2, "memory" => "2gb"}})
      repo

    repo ->
      repo
  end

{:ok, token} = Boxes.create_join_token(scope, %{"box_name" => box_name, "owner_user_id" => admin.id})

IO.puts("E2E_REPO_ID=#{repo.id}")
IO.puts("E2E_JOIN_TOKEN=#{token}")
