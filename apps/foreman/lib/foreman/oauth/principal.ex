defmodule Foreman.OAuth.Principal do
  @moduledoc "The verified identity and authority of a public API connection."
  @enforce_keys [:user, :kind, :client_id, :scopes, :grant_id]
  # `environment_id` is set when the connection is an environment's own
  # (`Foreman.OAuth.EnvironmentConnection`): it acts as the owner, and
  # reaches that environment and nothing else of theirs.
  defstruct @enforce_keys ++ [environment_id: nil]

  @type t :: %__MODULE__{
          user: Foreman.Accounts.User.t(),
          kind: :user | :service_account,
          client_id: String.t(),
          scopes: [String.t()],
          grant_id: Ecto.UUID.t(),
          environment_id: Ecto.UUID.t() | nil
        }
end
