defmodule ForemanWeb.ChannelCase do
  @moduledoc "Tests for the agent socket and channel."

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false) and Foreman.Repo.database() == "postgres"

    quote do
      use ExUnit.Case, async: unquote(async)

      import Phoenix.ChannelTest
      import ForemanWeb.ChannelCase
      import Foreman.Fixtures

      @endpoint ForemanWeb.Endpoint

      setup tags do
        Foreman.DataCase.setup_sandbox(tags)
        :ok
      end
    end
  end

  @doc "connect_info for a socket connect signed with `box`'s key."
  def signed_connect_info(box, opts \\ []) do
    headers = ForemanProtocol.Auth.connect_headers(box.id, box.__private_key__, opts)

    %{
      x_headers: Enum.to_list(headers),
      peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil}
    }
  end

  def join_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "agent_version" => "0.1.0",
        "protocol_version" => ForemanProtocol.version(),
        "hostname" => "desktop",
        "os" => "linux",
        "arch" => "linux-arm64",
        "in_flight" => []
      },
      overrides
    )
  end
end
