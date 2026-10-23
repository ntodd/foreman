# Helpers e2e/updater/run.sh calls inside the control plane image:
#   bin/foreman eval 'Code.eval_file("/e2e/eval.exs"); E2E.request("0.9.2")'
defmodule E2E do
  alias Foreman.{Accounts, Repo, Scope, Updates}

  defp start, do: {:ok, _} = Application.ensure_all_started(:foreman)

  def seed do
    start()

    Repo.insert!(%Accounts.User{
      login: "e2e",
      github_id: 1,
      name: "E2E",
      role: "admin",
      access_token: "ghu_e2e",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 8 * 3600),
      refresh_token: "ghr_e2e",
      refresh_token_expires_at: DateTime.add(DateTime.utc_now(), 86_400 * 180)
    })

    IO.puts("SEEDED")
  end

  def users do
    start()
    IO.puts("USERS #{Repo.aggregate(Accounts.User, :count)}")
  end

  # As if the release check had found `version`, then the admin's click.
  def request(version) do
    start()
    :persistent_term.put({Updates, :latest}, %{version: version, url: nil, checked_at: nil, error: nil})
    scope = Scope.for_user(Accounts.get_user_by_login("e2e"))
    IO.puts("REQUEST #{inspect(Updates.request(scope, version))}")
  end

  def updater do
    start()
    %{installed: installed, state: state} = Updates.updater()
    IO.puts("UPDATER installed=#{installed} state=#{state}")
  end
end
