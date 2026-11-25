defmodule Foreman.ReposAttachmentTokenTest do
  use Foreman.DataCase

  import Mox

  alias Foreman.{Audit, Repos, Scope}
  alias Foreman.GitHub.ClientMock

  setup :verify_on_exit!

  setup do
    %{
      admin: Scope.for_user(user_fixture(role: "admin")),
      owner: owner_fixture(login: "acme")
    }
  end

  test "an admin saves a fine-grained token GitHub accepts, with whose it is", ctx do
    expires = ~U[2027-11-25 00:00:00.000000Z]

    expect(ClientMock, :check_token, fn "github_pat_bot" ->
      {:ok, %{login: "acme-bot", scopes: [], expires_at: expires}}
    end)

    assert {:ok, owner} = Repos.update_attachment_token(ctx.admin, ctx.owner, " github_pat_bot ")

    assert owner.attachment_token == "github_pat_bot"
    assert owner.attachment_login == "acme-bot"
    assert owner.attachment_token_expires_at == expires
    assert owner.attachment_checked_at

    assert [event] = Enum.filter(Audit.recent(), &(&1.action == "owner.attachment_token"))
    assert event.metadata == %{"login" => "acme-bot", "set" => true}
    refute inspect(event) =~ "github_pat_bot"
  end

  test "the token never reaches the query log", ctx do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    stub(ClientMock, :check_token, fn _ ->
      {:ok, %{login: "acme-bot", scopes: [], expires_at: nil}}
    end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        {:ok, _} = Repos.update_attachment_token(ctx.admin, ctx.owner, "github_pat_s3cret")
      end)

    # The capture is live: the audit row written beside the token is in it.
    assert log =~ "audit_events"
    refute log =~ "github_pat_s3cret"
  end

  test "takes the login GitHub gives a managed user, underscore and all", ctx do
    expect(ClientMock, :check_token, fn _ ->
      {:ok, %{login: "foreman-bot_acme", scopes: [], expires_at: nil}}
    end)

    assert {:ok, owner} = Repos.update_attachment_token(ctx.admin, ctx.owner, "github_pat_emu")
    assert owner.attachment_login == "foreman-bot_acme"
  end

  test "writes all of what it checked, whatever the page it was opened on showed", ctx do
    expires = ~U[2027-01-01 00:00:00.000000Z]

    # The owner as a form opened a while ago has it.
    stale =
      ctx.owner
      |> change(attachment_login: "first-bot", attachment_token_expires_at: expires)
      |> Repo.update!()

    # Someone else replaced the token since.
    stale
    |> change(attachment_login: "second-bot", attachment_token_expires_at: nil)
    |> Repo.update!()

    expect(ClientMock, :check_token, fn _ ->
      {:ok, %{login: "first-bot", scopes: [], expires_at: expires}}
    end)

    assert {:ok, _} = Repos.update_attachment_token(ctx.admin, stale, "github_pat_first")

    saved = Repo.reload!(ctx.owner)
    assert saved.attachment_token == "github_pat_first"
    assert saved.attachment_login == "first-bot"
    assert saved.attachment_token_expires_at == expires
  end

  test "a classic or app token is refused before GitHub is asked", ctx do
    for token <- ["ghp_classic", "gho_oauth", "ghs_installation", "nonsense"] do
      assert {:error, message} = Repos.update_attachment_token(ctx.admin, ctx.owner, token)
      assert message =~ "fine-grained"
    end

    assert Repo.reload!(ctx.owner).attachment_token == nil
  end

  test "a token GitHub rejects isn't saved", ctx do
    expect(ClientMock, :check_token, fn _ -> {:error, :invalid_token} end)

    assert {:error, "GitHub rejected the token"} =
             Repos.update_attachment_token(ctx.admin, ctx.owner, "github_pat_revoked")

    assert Repo.reload!(ctx.owner).attachment_token == nil
  end

  test "an empty token removes the one that was set", ctx do
    owner =
      ctx.owner
      |> change(attachment_token: "github_pat_bot", attachment_login: "acme-bot")
      |> Repo.update!()

    assert {:ok, owner} = Repos.update_attachment_token(ctx.admin, owner, "")
    assert owner.attachment_token == nil
    assert owner.attachment_login == nil

    assert [event] = Enum.filter(Audit.recent(), &(&1.action == "owner.attachment_token"))
    assert event.metadata == %{"login" => nil, "set" => false}
  end

  test "only an admin sets one", ctx do
    member = Scope.for_user(user_fixture())

    assert {:error, :unauthorized} =
             Repos.update_attachment_token(member, ctx.owner, "github_pat_bot")
  end
end
