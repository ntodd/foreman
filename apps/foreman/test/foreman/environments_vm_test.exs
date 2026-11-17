defmodule Foreman.EnvironmentsVMTest do
  @moduledoc """
  Every environment runs in a VM of its own (protocol 6), so a box that
  can't run VMs, or whose agent predates them, gets no new environments.
  """
  use Foreman.DataCase, async: true

  import Foreman.Fixtures

  alias Foreman.{Boxes, Environments, Scope}

  setup do
    user = user_fixture()
    %{scope: Scope.for_user(user), user: user, repo: repo_fixture()}
  end

  test "a box that can run VMs takes environments", %{scope: scope, user: user, repo: repo} do
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true, "nested" => false})
    assert Boxes.vm_problem(Repo.reload!(box)) == nil

    assert {:ok, _env} =
             Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})
  end

  test "a box that hasn't said yet takes environments", %{scope: scope, user: user, repo: repo} do
    box = box_fixture(owner_user_id: user.id)

    assert {:ok, _env} =
             Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})
  end

  test "a box without KVM doesn't, and says why", %{scope: scope, user: user, repo: repo} do
    box =
      box_fixture(
        owner_user_id: user.id,
        vm: %{"ready" => false, "reason" => "this box has no /dev/kvm"}
      )

    assert {:error, message} =
             Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

    assert message == "#{box.name} can't run environments: this box has no /dev/kvm"
  end

  test "a box whose agent predates VMs doesn't", %{scope: scope, user: user, repo: repo} do
    box = box_fixture(owner_user_id: user.id, protocol_version: 5)

    assert {:error, message} =
             Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

    assert message =~ "predates environment VMs; run the install script on it again"
  end
end
