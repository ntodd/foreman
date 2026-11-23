defmodule ForemanWeb.OAuthAdminHTML do
  use ForemanWeb, :html

  def index(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/admin/apps"
      width="narrow"
    >
      <.header>API clients</.header>
      <section :if={@credential} class="space-y-2 rounded border border-line p-4">
        <h2 class="font-semibold">Save this credential now</h2>
        <p>Client ID <code>{elem(@credential, 0)}</code></p>
        <p>Client secret <code class="break-all">{elem(@credential, 1)}</code></p>
      </section>
      <section :for={client <- @clients} class="space-y-2 border-b border-line py-4">
        <h2 class="font-semibold">{client.name}</h2>
        <p>
          <code>{client.id}</code>
          · {client.kind} · {if client.disabled_at, do: "Disabled", else: "Active"}
        </p>
        <%= if install = @installations[client.id] do %>
          <dl class="space-y-1 break-words">
            <dt>Service identity</dt><dd>{install.user_id}</dd>
            <dt>Permissions</dt><dd>{Enum.join(install.scopes, ", ")}</dd>
            <dt>Repositories</dt><dd>{Enum.join(install.repo_ids, ", ")}</dd>
            <dt>Boxes</dt><dd>{Enum.join(install.box_ids, ", ")}</dd>
            <dt>Workload secrets</dt><dd>{Enum.join(install.secret_ids, ", ")}</dd>
            <dt>Service tailnet tags</dt><dd>
              {Enum.join(install.network_policy["tailscale_tags"], ", ")}
            </dd>
          </dl>
          <p :if={client.disabled_at}>
            Review SSH access for these tags with your tailnet administrator.
          </p>
          <.form
            :if={!client.disabled_at}
            for={%{}}
            id={"rotate-#{client.id}"}
            action={~p"/admin/apps/#{client.id}/rotate"}
          >
            <.button type="submit">Rotate secret</.button>
          </.form>
        <% end %>
        <.form
          :if={client.id != "foreman-cli" and !client.disabled_at}
          for={%{}}
          id={"disable-#{client.id}"}
          action={~p"/admin/apps/#{client.id}/disable"}
        >
          <.button type="submit" variant="danger_outline">Disable client</.button>
        </.form>
      </section>
      <.form for={%{}} id="register-public" action={~p"/admin/apps"} class="space-y-3 py-5">
        <h2 class="font-semibold">Register a public app</h2>
        <input type="hidden" name="kind" value="public" />
        <.input name="name" value="" label="App name shown at consent" required maxlength="120" />
        <.button type="submit">Register app</.button>
      </.form>
      <.form for={%{}} id="install-service" action={~p"/admin/apps"} class="space-y-3 py-5">
        <h2 class="font-semibold">Install a service account</h2>
        <input type="hidden" name="kind" value="service" />
        <.input name="name" value="" label="Service name" required maxlength="120" />
        <fieldset>
          <legend>Permissions</legend>
          <label :for={s <- @scopes} class="block"><input type="checkbox" name="scopes[]" value={s} /> {s}</label>
        </fieldset>
        <fieldset>
          <legend>Repositories</legend>
          <label :for={{id, name} <- @choices.repos} class="block"><input
            type="checkbox"
            name="repo_ids[]"
            value={id}
          /> {name}</label>
        </fieldset>
        <fieldset>
          <legend>Boxes</legend>
          <label :for={{id, name} <- @choices.boxes} class="block"><input
            type="checkbox"
            name="box_ids[]"
            value={id}
          /> {name}</label>
        </fieldset>
        <fieldset>
          <legend>Workload secrets</legend>
          <label :for={{id, name, subject} <- @choices.secrets} class="block"><input
            type="checkbox"
            name="secret_ids[]"
            value={id}
          /> {name} ({subject})</label>
        </fieldset>
        <.input name="tailscale_tags" value="" label="Additional tailnet tags (comma-separated)" />
        <p>Each installation also receives its own service tag for tailnet access rules.</p>
        <.button type="submit" variant="primary">Install</.button>
      </.form>
    </Layouts.app>
    """
  end
end
