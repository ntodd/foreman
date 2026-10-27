defmodule Foreman.BoxesRebootTest do
  @moduledoc "Whether a box needs a reboot, as its agent reports it."
  use Foreman.DataCase

  alias Foreman.{Activity, Boxes, Scope}
  alias ForemanWeb.ActivityNotice

  setup do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id, name: "desk")
    Activity.subscribe(Scope.for_user(user))
    %{box: box}
  end

  defp report(box, required, packages \\ [], livepatch \\ false),
    do:
      Boxes.record_reboot(box.id, %{required: required, packages: packages, livepatch: livepatch})

  test "records the report", %{box: box} do
    :ok = report(box, true, ["libc6"], true)
    box = Repo.reload!(box)
    assert {box.reboot_required, box.reboot_packages, box.livepatch} == {true, ["libc6"], true}
  end

  test "tells everyone who can see the box once it starts needing one", %{box: box} do
    :ok = report(box, false)
    refute_receive {:activity, _}

    :ok = report(box, true, ["libc6"])
    assert_receive {:activity, %Activity{kind: :box_reboot_required} = event}
    assert {:info, %{title: "desk", text: "Needs a reboot"}} = ActivityNotice.flash(event)

    # The agent reports it again after every join and on any change.
    :ok = report(box, true, ["libc6", "openssl"])
    refute_receive {:activity, _}

    :ok = report(box, false)
    :ok = report(box, true, ["linux-image-6.8.0-90-generic"], true)
    assert_receive {:activity, %Activity{kind: :box_reboot_required}}
  end

  # A box already waiting on a reboot when its agent first reports it is
  # news too.
  test "tells them on the first report, if it needs one", %{box: box} do
    :ok = report(box, true, ["libc6"])
    assert_receive {:activity, %Activity{kind: :box_reboot_required}}
  end

  describe "reboot_needed/1" do
    test "nil when it doesn't, or the agent doesn't say" do
      assert Boxes.reboot_needed(%Boxes.Box{reboot_required: false}) == nil
      assert Boxes.reboot_needed(%Boxes.Box{reboot_required: nil}) == nil
    end

    # A livepatch doesn't say the pending kernel is covered, and Livepatch
    # clients that can tell remove the flag themselves.
    test ":required whenever the flag is there, livepatch or not" do
      for livepatch <- [true, false, nil], packages <- [[], ["linux-image-6.8.0-90-generic"]] do
        assert Boxes.reboot_needed(%Boxes.Box{
                 reboot_required: true,
                 reboot_packages: packages,
                 livepatch: livepatch
               }) == :required
      end
    end
  end
end
