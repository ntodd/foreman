defmodule Foreman.OAuth.Principal do
  @moduledoc "The verified identity and authority of a public API connection."
  @enforce_keys [:user, :kind, :client_id, :scopes, :grant_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          user: Foreman.Accounts.User.t(),
          kind: :user | :service_account,
          client_id: String.t(),
          scopes: [String.t()],
          grant_id: Ecto.UUID.t()
        }
end
