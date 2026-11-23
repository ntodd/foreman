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
