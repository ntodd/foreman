defmodule Foreman.OAuth.Scopes do
  @moduledoc "Actions an app can request when connecting to the public API."

  @actions ~w(repos:list boxes:list environments:list environments:read operations:list
              operations:read logs:read environments:create environments:start
              environments:stop environments:destroy secrets:list secrets:write)

  # A person manages secrets through their own connection. A service
  # account gets the secrets an admin approved for it and manages none.
  @personal ~w(secrets:list secrets:write)

  def all, do: @actions

  @doc "The actions an admin can grant a service account."
  def service, do: @actions -- @personal
end
