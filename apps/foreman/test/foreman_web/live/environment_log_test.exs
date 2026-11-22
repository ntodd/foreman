defmodule ForemanWeb.EnvironmentLogTest do
  use ForemanWeb.ConnCase

  setup :register_and_log_in_admin

  test "trimming a followed log keeps complete UTF-8 characters", %{conn: conn, user: user} do
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, box: box)

    op =
      Foreman.Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: env.id,
        box_id: box.id,
        action: "rebuild",
        command: "env.rebuild",
        status: "running",
        args: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}?op=#{op.id}")
    sequence = System.unique_integer([:monotonic, :positive])
    send(view.pid, {:op_log, op.id, sequence, String.duplicate("━", 133_400) <> "x"})
    assert_push_event view, "operation-log", %{text: log, cursor: cursor, reset: true}
    assert String.valid?(log)
    assert log == String.duplicate("━", 99_999) <> "x"

    send(view.pid, {:op_log, op.id, sequence + 1, "next line"})
    assert_push_event view, "operation-log", %{text: "next line", cursor: ^cursor, reset: false}
    assert :sys.get_state(view.pid).socket.assigns.log == ""
  end
end
