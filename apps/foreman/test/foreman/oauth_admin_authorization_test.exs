defmodule Foreman.OAuthAdminAuthorizationTest do
  use Foreman.DataCase
  alias Foreman.{Accounts, Scope}
  alias Foreman.OAuth.ServiceAccounts

  for mutation <- [:register, :rotate, :disable] do
    @mutation mutation
    test "#{mutation} checks the administrator's current authority" do
      admin = user_fixture(role: "admin")
      scope = Scope.for_user(admin)
      attrs = %{"name" => "Test service", "scopes" => ["repos:list"]}
      {:ok, %{client: client}} = ServiceAccounts.register(scope, "service", attrs)

      for change <- [:demoted, :disabled, :unlisted_config_admin, :offboarded] do
        Repo.update!(
          change(Repo.reload!(admin), role: "admin", disabled_at: nil, admin_via_config: false)
        )

        case change do
          :demoted ->
            Repo.update!(change(Repo.reload!(admin), role: "member"))

          :disabled ->
            Repo.update!(change(Repo.reload!(admin), disabled_at: DateTime.utc_now()))

          :unlisted_config_admin ->
            Repo.update!(change(Repo.reload!(admin), admin_via_config: true))

          :offboarded ->
            Accounts.revoke_access(admin, "no longer a member")
        end

        result =
          case @mutation do
            :register -> ServiceAccounts.register(scope, "service", attrs)
            :rotate -> ServiceAccounts.rotate(scope, client.id)
            :disable -> ServiceAccounts.disable(scope, client.id)
          end

        assert {:error, :unauthorized} == result, "#{@mutation} by #{change} administrator"
      end

      assert Repo.reload!(client).secret_hash == client.secret_hash
      assert is_nil(Repo.reload!(client).disabled_at)
    end
  end
end
