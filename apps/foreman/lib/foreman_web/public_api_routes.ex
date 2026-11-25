defmodule ForemanWeb.PublicAPIRoutes do
  @moduledoc """
  The public API's routes, written once. The router mounts them for
  bearer tokens under `/api/v1` and, signed by a box for one of its
  environments, under `/api/agents/relay/v1`: a route added here is in
  both.
  """

  defmacro public_api_routes do
    quote do
      get "/me", ForemanWeb.IdentityController, :show
      post "/environments", ForemanWeb.EnvironmentMutationController, :create
      post "/environments/:id/operations", ForemanWeb.EnvironmentMutationController, :operate
      # Unlogged: a body that isn't shaped the way the API expects is logged
      # before anything can validate it, and its values are secrets.
      patch "/secrets/:scope/:subject", ForemanWeb.SecretMutationController, :update, log: false
      post "/environments/:id/attachments", ForemanWeb.AttachmentController, :create
      # Unlogged: a chunk's parameters are half a megabyte of someone's file.
      patch "/environments/:id/attachments/:attachment_id",
            ForemanWeb.AttachmentController,
            :append,
            log: false

      get "/repos", ForemanWeb.PublicReadController, :repos
      get "/boxes", ForemanWeb.PublicReadController, :boxes
      get "/environments", ForemanWeb.PublicReadController, :environments
      get "/environments/:id", ForemanWeb.PublicReadController, :environment
      get "/environments/:id/operations", ForemanWeb.PublicReadController, :operations
      get "/operations/:id", ForemanWeb.PublicReadController, :operation
      get "/operations/:id/logs", ForemanWeb.PublicReadController, :logs
      get "/secrets/:scope/:subject", ForemanWeb.PublicReadController, :secrets
    end
  end
end
