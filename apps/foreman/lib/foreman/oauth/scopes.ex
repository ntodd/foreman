defmodule Foreman.OAuth.Scopes do
  @moduledoc "Actions an app can request when connecting to the public API."

  @actions ~w(repos:list boxes:list environments:list environments:read operations:list
              operations:read logs:read environments:create environments:start
              environments:stop environments:destroy)

  def all, do: @actions
end
