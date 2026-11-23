defmodule ForemanWeb.ConsentHTML do
  use ForemanWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <.header>Connect a device</.header>
      <%= if @device do %>
        <.form for={%{}} action={~p"/oauth/device"} id="device-consent" class="space-y-4">
          <p>
            Connect <strong>{@device.client.name}</strong>
            as <strong>{@current_scope.user.login}</strong>?
          </p>
          <p>Client ID <code>{@device.client.id}</code></p>
          <p>Confirm your device shows <strong class="font-mono">{@user_code}</strong>.</p>
          <input type="hidden" name="user_code" value={@user_code} />
          <p>This app is requesting these permissions:</p>
          <ul class="list-inside list-disc">
            <li :for={scope <- @device.scopes}>{scope}</li>
          </ul>
          <.button type="submit" name="decision" value="approve" variant="primary">Approve</.button>
          <.button type="submit" name="decision" value="deny">Deny</.button>
        </.form>
      <% else %>
        <.form for={%{}} action={~p"/oauth/device"} method="get" id="lookup-code" class="space-y-4">
          <p :if={@invalid} role="alert">That code is invalid, expired, or already used.</p>
          <.input
            type="text"
            name="user_code"
            value=""
            label="Code shown on your device"
            required
            maxlength="16"
            autocomplete="off"
          />
          <.button type="submit" variant="primary">Review permissions</.button>
        </.form>
      <% end %>
    </Layouts.app>
    """
  end

  def result(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <.header>Device authorization</.header>
      <p id="decision-result">
        {if @decision == "approve", do: "Approved. Return to your device.", else: "Connection denied."}
      </p>
    </Layouts.app>
    """
  end

  def connections(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/settings/connections"
      width="narrow"
    >
      <.header>Connected apps</.header>
      <p :if={@grants == []}>You have no active connections.</p>
      <article :for={grant <- @grants} class="space-y-2 border-b border-line py-4">
        <h2 class="font-semibold">{grant.client.name}</h2>
        <p>Connected {Calendar.strftime(grant.inserted_at, "%Y-%m-%d %H:%M UTC")}</p>
        <p>{Enum.join(grant.scopes, ", ")}</p>
        <.form
          for={%{}}
          action={~p"/settings/connections/#{grant.id}/revoke"}
          id={"revoke-#{grant.id}"}
        >
          <.button type="submit">Revoke connection</.button>
        </.form>
      </article>
    </Layouts.app>
    """
  end
end
