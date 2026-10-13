defmodule Foreman do
  @moduledoc """
  The Foreman control plane's core: accounts, repos, boxes, environments,
  secrets and the integrations with GitHub and Tailscale. `ForemanWeb`
  depends on it, never the other way around.
  """
  use Boundary, deps: [], exports: :all
end
