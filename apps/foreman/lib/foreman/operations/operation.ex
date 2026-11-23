defmodule Foreman.Operations.Operation do
  @moduledoc """
  One command sent to an agent, and its log and outcome. The id is the
  command's op_id, so a resend after a reconnect is recognised by the agent.
  Payloads aren't stored: they carry secrets.
  """
  use Foreman.Schema

  @statuses ~w(queued dispatched running succeeded failed cancelled)

  schema "operations" do
    belongs_to :environment, Foreman.Environments.Environment
    belongs_to :box, Foreman.Boxes.Box
    belongs_to :user, Foreman.Accounts.User
    field :api_grant_id, :binary_id
    field :trigger, :string, default: "request"
    field :action, :string
    field :command, :string
    field :args, :map
    field :status, :string, default: "queued"
    field :error, :string
    field :timeout_error, :string
    field :result, :map
    field :log, :string, load_in_query: false
    field :log_truncated, :boolean, default: false
    field :dispatched_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :cancel_requested_at, :utc_datetime_usec
    timestamps()
  end

  def statuses, do: @statuses

  def finished?(%__MODULE__{status: status}), do: status in ~w(succeeded failed cancelled)
end
