defmodule ForemanWeb.FleetOverviewTest do
  @moduledoc """
  The fleet's totals: the home page's capacity summary with the boxes
  that need attention, and the Boxes page's totals row.
  """
  use ForemanWeb.ConnCase

  setup :register_and_log_in_admin

  # A box whose environments cold-boot at 2 CPUs and 4 GiB.
  @vm %{
    "default_cpus" => 2,
    "default_memory_mb" => 4_096,
    "host_cpus" => 16,
    "host_memory_mb" => 65_536
  }

  defp online(box) do
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    box
  end

  defp healthy(user, name),
    do:
      box_fixture(
        owner_user_id: user.id,
        name: name,
        vm: @vm,
        firewall: "active",
        firewall_default_bridge: "filtered"
      )

  describe "with two boxes online and one away" do
    setup %{user: user} do
      desktop = online(healthy(user, "desktop"))
      rack = online(healthy(user, "rack"))
      away = healthy(user, "away")

      environment_fixture(user: user, box: desktop)
      environment_fixture(user: user, box: rack)

      environment_fixture(
        user: user,
        box: rack,
        desired_state: "stopped",
        observed_state: "stopped"
      )

      %{desktop: desktop, rack: rack, away: away}
    end

    test "the home page sums what the online boxes offer and hold", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#fleet-online", "2 / 3")
      assert has_element?(view, "#fleet-cpu", "4 / 32 cores")
      assert has_element?(view, "#fleet-memory", "8.0 / 128 GiB")
      assert has_element?(view, "#fleet-environments", "3")
      assert has_element?(view, "#fleet-environments", "2 running")
      assert has_element?(view, "#fleet-environments", "1 stopped")
      assert has_element?(view, "#fleet a[href='/boxes']")
    end

    test "the home page names the boxes that need attention", %{
      conn: conn,
      desktop: desktop,
      away: away
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#fleet-online", "1 needs attention")
      assert has_element?(view, "#fleet-attention-#{away.id}", "Offline")
      assert has_element?(view, "#fleet-attention-#{away.id} a[href='/boxes/#{away.id}']", "away")
      refute has_element?(view, "#fleet-attention-#{desktop.id}")
    end

    test "the Boxes page totals the fleet above its cards", %{conn: conn, rack: rack} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      assert has_element?(view, "#fleet-boxes", "2 of 3")
      assert has_element?(view, "#fleet-boxes", "1 needs attention")
      assert has_element?(view, "#fleet-cores", "32")
      assert has_element?(view, "#fleet-cores", "4 provisioned")
      assert has_element?(view, "#fleet-memory", "128")
      assert has_element?(view, "#fleet-memory", "8.0 GiB provisioned")
      assert has_element?(view, "#fleet-environments", "3")
      assert has_element?(view, "#boxes-live", "Live")

      assert has_element?(view, "#box-#{rack.id}-summary", "16 cores")
      assert has_element?(view, "#box-#{rack.id}-summary", "2 environments")
    end
  end

  test "a healthy fleet has nothing to attend to", %{conn: conn, user: user} do
    online(healthy(user, "desktop"))

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#fleet-online", "1 / 1")
    assert has_element?(view, "#fleet-online", "All healthy")
    refute has_element?(view, "#fleet-attention")

    {:ok, view, _html} = live(conn, ~p"/boxes")
    assert has_element?(view, "#fleet-boxes", "All healthy")
  end

  test "an admin can jump to the add-box form from the Boxes header", %{conn: conn, user: user} do
    healthy(user, "desktop")
    {:ok, view, _html} = live(conn, ~p"/boxes")
    assert has_element?(view, "header a[href='#add-box']", "Add box")
  end

  test "without boxes there's no fleet summary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#fleet")

    {:ok, view, _html} = live(conn, ~p"/boxes")
    refute has_element?(view, "#fleet")
    assert has_element?(view, "#no-boxes")
  end
end
