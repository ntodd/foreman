defmodule ForemanAgent.PreloadedCodeTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Test.Preload

  # A test that waits on a process shouldn't also be waiting on the code
  # server to load what that process calls for the first time.
  test "the agent's code is loaded before the tests run" do
    modules = Enum.flat_map(Preload.apps(), &(Application.spec(&1, :modules) || []))

    # What an operation calls first, so the list can't come up empty.
    assert ForemanAgent.Text in modules
    assert Enum.reject(modules, &:code.is_loaded/1) == []
  end
end
