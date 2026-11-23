defmodule Foreman.Operations.LogStore do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Query
  alias Foreman.Operations.Operation
  alias Foreman.Repo

  @primary_key false
  schema "operation_log_chunks" do
    field :operation_id, :binary_id, primary_key: true
    field :end_offset, :integer, primary_key: true
    field :data, :binary
  end

  @limit 1_048_576
  @chunk_size 65_536

  def read(op_id, pending) do
    parts = Repo.all(from c in chunks(op_id), order_by: c.end_offset, select: c.data)
    prefix = if parts == [], do: legacy(op_id) || "", else: parts
    tail(IO.iodata_to_binary([prefix, pending])) |> String.replace_invalid()
  end

  @doc """
  Reads a bounded page of already-redacted, durable bytes at an absolute
  offset. Polling an empty page keeps the position until the buffer flushes.
  A reader overtaken by the rolling tail resumes at its oldest retained byte.
  """
  def page(op, offset) do
    query = chunks(op.id)

    case Repo.one(from c in query, select: max(c.end_offset)) do
      nil ->
        # Once the first writer migrates a legacy log, its offsets continue
        # from that log's length. An empty poll racing migration is retryable.
        data = legacy(op.id) || ""
        slice(data, 0, offset, op.log_truncated and offset == 0)

      ending ->
        first = max(offset, ending - @limit)

        rows =
          Repo.all(
            from c in query,
              where: c.end_offset > ^first and c.end_offset <= ^ending,
              order_by: c.end_offset,
              limit: 128,
              select: {c.end_offset, c.data},
              where: c.end_offset <= ^(first + 2 * @chunk_size)
          )

        case rows do
          [] ->
            {"", offset, false}

          [{to, head} | _] ->
            base = to - byte_size(head)
            start = max(first, base)
            data = rows |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
            slice(data, base, start, offset < start or (offset == 0 and op.log_truncated))
        end
    end
  end

  defp slice(data, base, start, truncated) do
    skip = min(max(0, start - base), byte_size(data))
    remaining = binary_part(data, skip, byte_size(data) - skip)
    {aligned, position} = align(remaining, start)
    # The row or page can end inside a code point. Leave those bytes for
    # the next page, whose cursor counts the original stored bytes.
    bytes = String.byte_slice(aligned, 0, @chunk_size)
    {String.replace_invalid(bytes), position + byte_size(bytes), truncated}
  end

  # The rolling tail can cut away the leading bytes of a UTF-8 scalar.
  defp align(<<continuation, rest::binary>>, position) when continuation in 128..191,
    do: align(rest, position + 1)

  defp align(bytes, position), do: {bytes, position}

  def append(op_id, text) do
    Repo.transact(fn ->
      query = from o in Operation, where: o.id == ^op_id, select: o.id
      query = if Repo.sqlite?(), do: query, else: lock(query, "FOR UPDATE")
      if Repo.one(query), do: write(op_id, text)
      {:ok, :ok}
    end)
  end

  defp write(op_id, text) do
    last = Repo.one(from c in chunks(op_id), select: max(c.end_offset))
    # Only the first append to an operation can need its pre-upgrade log.
    old = if is_nil(last), do: legacy(op_id)
    data = (old || "") <> text
    ending = (last || 0) + byte_size(data)
    kept = tail(data)
    rows = split(kept, op_id, ending - byte_size(kept), [])
    Repo.insert_all(__MODULE__, rows)

    if old do
      Repo.update_all(from(o in Operation, where: o.id == ^op_id), set: [log: nil])
    end

    if ending > @limit do
      Repo.delete_all(from c in chunks(op_id), where: c.end_offset <= ^(ending - @limit))

      Repo.update_all(from(o in Operation, where: o.id == ^op_id and not o.log_truncated),
        set: [log_truncated: true]
      )
    end
  end

  defp split("", _id, _offset, rows), do: rows

  defp split(data, id, offset, rows) do
    size = min(byte_size(data), @chunk_size)
    <<part::binary-size(^size), rest::binary>> = data
    row = %{operation_id: id, end_offset: offset + size, data: part}
    split(rest, id, offset + size, [row | rows])
  end

  defp chunks(id), do: from(c in __MODULE__, where: c.operation_id == ^id)
  defp legacy(id), do: Repo.one(from o in Operation, where: o.id == ^id, select: o.log)
  defp tail(data) when byte_size(data) > @limit, do: String.byte_slice(data, -@limit, @limit)
  defp tail(data), do: data
end
