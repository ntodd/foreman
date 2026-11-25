defmodule Foreman.OAuth.Scopes do
  @moduledoc "Actions an app can request when connecting to the public API."

  @actions ~w(repos:list boxes:list environments:list environments:read operations:list
              operations:read logs:read environments:create environments:start
              environments:stop environments:destroy secrets:list secrets:write
              attachments:create)

  # A person manages secrets through their own connection. A service
  # account gets the secrets an admin approved for it and manages none.
  # Attachments go up as files a person's environment made
  # (`Foreman.Attachments`), and a service account's environment has no
  # connection of its own to send them through.
  @personal ~w(secrets:list secrets:write attachments:create)

  def all, do: @actions

  # What an environment can do to itself from inside: read its own state,
  # operations and logs, manage its own secrets, stop, start and restart,
  # and attach files to its repository's issues and pull requests. Never
  # destroy or create, and nothing that lists what else its owner can
  # reach.
  @environment ~w(environments:list environments:read operations:list operations:read
                  logs:read environments:start environments:stop secrets:list secrets:write
                  attachments:create)

  @doc "The actions an environment's own connection carries."
  def environment, do: @environment

  @doc "The actions an admin can grant a service account."
  def service, do: @actions -- @personal
end
