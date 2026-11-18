defmodule ForemanAgent.PreloadTest do
  use ExUnit.Case, async: true

  # A module loaded on first use waits on the code server, which is busy
  # loading test files while the first async tests run. See test_helper.exs.
  test "the agent's modules are loaded before the tests start" do
    for app <- [:foreman_agent, :foreman_protocol],
        module <- Application.spec(app, :modules) do
      assert :code.is_loaded(module), "#{inspect(module)} isn't loaded"
    end
  end
end
