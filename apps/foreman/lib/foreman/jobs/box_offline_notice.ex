defmodule Foreman.Jobs.BoxOfflineNotice do
  @moduledoc """
  Tells people a box went offline, if it's still offline a minute after
  its agent left. Agent updates and control plane deploys drop the
  connection for a few seconds, which isn't news.

  `left_at` is the box's last_seen_at when the agent left: if it moved,
  the agent came back (and maybe left again, with its own notice queued).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Foreman.{Activity, Boxes}

  def enqueue(box) do
    %{"box_id" => box.id, "left_at" => DateTime.to_iso8601(box.last_seen_at)}
    |> new(schedule_in: Activity.offline_after_s())
    |> Oban.insert()
  end

  @impl true
  def perform(%Oban.Job{args: %{"box_id" => box_id, "left_at" => left_at}}) do
    with %{revoked_at: nil} = box <- Boxes.get_box(box_id),
         false <- Boxes.online?(box_id),
         true <- DateTime.to_iso8601(box.last_seen_at) == left_at do
      Activity.box_offline(box)
    end

    :ok
  end
end
