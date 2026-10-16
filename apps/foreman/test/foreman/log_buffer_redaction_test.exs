defmodule Foreman.LogBufferRedactionTest do
  @moduledoc """
  The agent sends container logs (`env.logs`) as raw pipe reads, and it
  can't scrub them itself (it doesn't know secrets.env values), so the
  control plane's redaction is the only defence. A secret mustn't get
  through by straddling two chunks.
  """
  use Foreman.DataCase

  alias Foreman.Operations
  alias Foreman.Operations.{LogBuffer, Redactions}
  alias ForemanProtocol.Command

  @secret "postgres://app:Hunter2-Very-Secret@db.internal/prod"

  setup do
    user = user_fixture()
    env = environment_fixture(user: user)

    {:ok, _} =
      Foreman.Secrets.put_secret(Foreman.Scope.for_user(user), "user", user, %{
        "name" => "DATABASE_URL",
        "value" => @secret
      })

    op =
      Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: env.id,
        box_id: env.box_id,
        user_id: user.id,
        action: "logs",
        command: "env.logs",
        args: %{},
        status: "running"
      })

    {:ok, cmd} = Command.new("env.logs", %{env_id: env.id, slug: env.slug}, op_id: op.id)
    :ok = Redactions.put(op.id, cmd, env)
    Operations.subscribe(op.id)

    # The buffer is shared and writes on a timer; write this test's text
    # while its database connection is still around.
    on_exit(fn -> LogBuffer.flush(op.id) end)
    %{op: op}
  end

  # Everything broadcast until it goes quiet. The buffer is shared, so on
  # a busy machine the first chunk can take a while.
  defp broadcast_text(op_id, acc \\ [], wait \\ 2_000) do
    receive do
      {:op_log, ^op_id, data} -> broadcast_text(op_id, [acc | data], 100)
    after
      wait -> IO.iodata_to_binary(acc)
    end
  end

  defp stored(op), do: Operations.log(Repo.reload!(op))

  test "a secret split across two chunks is scrubbed from the broadcast and the stored log",
       %{op: op} do
    {a, b} = String.split_at("app | connecting to #{@secret} ...\n", 40)

    LogBuffer.append(op.id, a)
    LogBuffer.append(op.id, b)

    shown = broadcast_text(op.id)
    LogBuffer.flush(op.id)

    assert shown == "app | connecting to [redacted] ...\n"
    assert stored(op) == "app | connecting to [redacted] ...\n"
  end

  test "a stream of 64 KiB reads never leaks a secret", %{op: op} do
    text = Enum.map_join(1..3_000, fn i -> "app | req #{i} db=#{@secret}\n" end)

    for <<chunk::binary-size(65_536) <- text>>, do: LogBuffer.append(op.id, chunk)
    whole = div(byte_size(text), 65_536) * 65_536
    LogBuffer.append(op.id, binary_part(text, whole, byte_size(text) - whole))
    LogBuffer.flush(op.id)

    log = stored(op)
    refute log =~ "Hunter2"
    assert length(String.split(log, "[redacted]")) - 1 == 3_000
  end

  test "a carriage return ends a line, so progress output isn't held back", %{op: op} do
    LogBuffer.append(op.id, "pulling 10%\rpulling 20%\r")
    assert broadcast_text(op.id) == "pulling 10%\rpulling 20%\r"
  end

  test "a trailing partial line is written when the operation's log is flushed", %{op: op} do
    LogBuffer.append(op.id, "done\nlast line without a newline #{@secret}")
    before_flush = broadcast_text(op.id)

    # On a slow machine the held line may already have gone out as idle;
    # either way it's shown once, scrubbed, and stored by the flush.
    LogBuffer.flush(op.id)
    shown = before_flush <> broadcast_text(op.id, [], 300)

    assert String.starts_with?(before_flush, "done\n")
    assert shown == "done\nlast line without a newline [redacted]"
    assert stored(op) == "done\nlast line without a newline [redacted]"
  end

  # Held text goes out after a pause; the part that could be the start of
  # a secret mustn't, or a secret split across a slow pair of reads leaks.
  test "a secret whose halves arrive more than the idle time apart is still scrubbed",
       %{op: op} do
    {a, b} = String.split_at(@secret, 20)

    LogBuffer.append(op.id, "connecting to " <> a)
    first = broadcast_text(op.id, [], 1_500)
    LogBuffer.append(op.id, b <> " ...\n")
    LogBuffer.flush(op.id)
    shown = first <> broadcast_text(op.id, [], 300)

    refute shown =~ a
    assert shown == "connecting to [redacted] ...\n"
    assert stored(op) == "connecting to [redacted] ...\n"
  end

  test "the start of a secret that never finishes isn't shown at the end", %{op: op} do
    {a, _} = String.split_at(@secret, 20)
    LogBuffer.append(op.id, "connecting to " <> a)
    LogBuffer.flush(op.id)

    refute stored(op) =~ a
    assert stored(op) == "connecting to [redacted]"
  end

  test "a partial line that sits for a while is shown without waiting for a newline",
       %{op: op} do
    LogBuffer.append(op.id, "Password: ")
    assert_receive {:op_log, _, "Password: "}, 3_000
  end

  test "an endless line is passed through once it's too long to hold", %{op: op} do
    line = String.duplicate("x", 70_000)
    LogBuffer.append(op.id, line)
    assert broadcast_text(op.id) == line
  end
end
