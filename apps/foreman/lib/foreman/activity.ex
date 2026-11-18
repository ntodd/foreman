defmodule Foreman.Activity do
  @moduledoc """
  What happened on a box, sent to everyone who can see it, whatever page
  they're on: an environment's create, start, stop, rebuild, restart or
  destroy finishing, an agent update finishing, and a box joining, going
  offline or coming back, and a box starting to need a reboot.

  Every LiveView subscribes (`ForemanWeb.UserAuth`) and shows an event as
  a notice. Pages keep their own topics for refreshing what they show;
  these events are only the news.

  An environment's events go to its owner and to admins (who see every
  environment), a box's to everyone, filtered by `visible?/2` on the way
  in.
  """

  alias Foreman.{Repo, Scope}
  alias Foreman.Boxes.Box
  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation

  defstruct [
    :kind,
    :action,
    :status,
    :error,
    :version,
    :subject,
    :env_id,
    :box_id,
    :box,
    :user_id
  ]

  @type t :: %__MODULE__{
          kind: :operation | :box_joined | :box_online | :box_offline | :box_reboot_required,
          action: String.t() | nil,
          status: String.t() | nil,
          error: String.t() | nil,
          version: String.t() | nil,
          subject: String.t(),
          env_id: Ecto.UUID.t() | nil,
          box_id: Ecto.UUID.t() | nil,
          box: Box.t() | nil,
          user_id: Ecto.UUID.t() | nil
        }

  @admins "activity:admins"
  @boxes "activity:boxes"

  # What a person started and waits on. Secrets writes, git status and
  # logs run behind other actions, or are answered on the page that asked.
  @env_actions ~w(create rebuild pull_rebuild start stop destroy restart_affected restart_all)

  # A reconnect quicker than this (an agent update, a control plane
  # deploy) isn't news; see `box_joined/2` and Jobs.BoxOfflineNotice.
  @offline_after_s 60

  def offline_after_s, do: @offline_after_s

  @doc "Subscribes the caller to the events `scope`'s user can see."
  def subscribe(%Scope{} = scope) do
    topic = if Scope.admin?(scope), do: @admins, else: user_topic(Scope.user_id(scope))
    Phoenix.PubSub.subscribe(Foreman.PubSub, topic)
    Phoenix.PubSub.subscribe(Foreman.PubSub, @boxes)
  end

  @doc "Whether `user` may see `event`. Environment events only reach those who can."
  def visible?(%__MODULE__{box: %Box{} = box}, user), do: Box.usable_by?(box, user)
  def visible?(%__MODULE__{}, _user), do: true

  @doc "Called when an operation finishes, however it finished."
  def operation_finished(%Operation{environment_id: env_id, action: action} = op)
      when is_binary(env_id) and action in @env_actions do
    with true <- op.status in ~w(succeeded failed),
         %Environment{} = env <- Repo.get(Environment, env_id) do
      event = %__MODULE__{
        kind: :operation,
        action: action,
        status: op.status,
        error: op.error,
        subject: env.slug,
        env_id: env.id,
        user_id: env.user_id
      }

      broadcast(user_topic(env.user_id), event)
      broadcast(@admins, event)
    end

    :ok
  end

  def operation_finished(%Operation{action: "agent.update", box_id: box_id} = op)
      when is_binary(box_id) do
    with true <- op.status in ~w(succeeded failed),
         %Box{} = box <- Repo.get(Box, box_id) do
      broadcast(@boxes, %{
        box_event(:operation, box)
        | action: op.action,
          status: op.status,
          error: op.error,
          version: (op.args || %{})["version"]
      })
    end

    :ok
  end

  def operation_finished(%Operation{}), do: :ok

  @doc """
  Called when a box's agent joins, with when it was last seen before
  that. The first join is a new box; one after a long absence is the box
  coming back.
  """
  def box_joined(%Box{} = box, nil), do: broadcast(@boxes, box_event(:box_joined, box))

  def box_joined(%Box{} = box, %DateTime{} = last_seen) do
    if DateTime.diff(DateTime.utc_now(), last_seen) >= @offline_after_s,
      do: broadcast(@boxes, box_event(:box_online, box)),
      else: :ok
  end

  @doc "Called once a box has stayed offline for `offline_after_s/0`."
  def box_offline(%Box{} = box), do: broadcast(@boxes, box_event(:box_offline, box))

  @doc "Called when a box's agent first reports that it needs a reboot."
  def box_reboot_required(%Box{} = box),
    do: broadcast(@boxes, box_event(:box_reboot_required, box))

  defp box_event(kind, box),
    do: %__MODULE__{kind: kind, subject: box.name, box_id: box.id, box: box}

  defp user_topic(user_id), do: "activity:user:#{user_id}"

  defp broadcast(topic, event),
    do: Phoenix.PubSub.broadcast(Foreman.PubSub, topic, {:activity, event})
end
