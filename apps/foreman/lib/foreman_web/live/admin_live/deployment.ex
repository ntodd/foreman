defmodule ForemanWeb.AdminLive.Deployment do
  @moduledoc """
  The deployment at a glance: GitHub and Tailscale, the database, owners
  with their secrets and registry credentials, and agent releases.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.Agents.Releases
  alias Foreman.{GitHub, Repos, Tailscale}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Deployment")
     |> assign(:registry_owner, nil)
     |> assign(:registry_form, nil)
     |> assign(:checking, false)
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:github_app, GitHub.app())
    |> assign(:tailscale, Tailscale.configured?())
    |> assign(:owners, Repos.list_owners())
    |> assign(:releases, Releases.list())
  end

  @impl true
  def handle_event("edit_registry", %{"id" => id}, socket) do
    owner = Repos.get_owner!(id)

    form =
      to_form(
        %{
          "host" => owner.registry_host || "ghcr.io",
          "username" => owner.registry_username || "",
          "token" => ""
        },
        as: :registry
      )

    {:noreply, assign(socket, registry_owner: owner, registry_form: form)}
  end

  def handle_event("cancel_registry", _params, socket),
    do: {:noreply, assign(socket, registry_owner: nil, registry_form: nil)}

  def handle_event("save_registry", %{"registry" => params}, socket) do
    owner = socket.assigns.registry_owner

    refs =
      Repos.list_repos()
      |> Enum.filter(&(&1.owner_id == owner.id))
      |> Enum.flat_map(& &1.private_registry_refs)
      |> Enum.uniq()

    host = String.trim(params["host"])
    username = String.trim(params["username"])
    token = String.trim(params["token"])
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:checking, true)
      |> start_async(:check_registry, fn ->
        case GitHub.check_registry_credential(host, username, token, refs) do
          {:ok, info} ->
            Repos.update_registry(scope, owner, %{
              registry_host: host,
              registry_username: username,
              registry_token: token,
              registry_token_expires_at: info.expires_at,
              registry_scopes: Enum.join(info.scopes, ","),
              registry_checked_at: DateTime.utc_now(),
              registry_error: nil
            })

          {:error, message} ->
            {:error, message}
        end
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:check_registry, {:ok, {:ok, owner}}, socket) do
    {:noreply,
     socket
     |> assign(checking: false, registry_owner: nil, registry_form: nil)
     |> put_flash(:info, "Checked and saved the registry credential for #{owner.login}.")
     |> load()}
  end

  def handle_async(:check_registry, {:ok, {:error, message}}, socket) do
    {:noreply, socket |> assign(:checking, false) |> put_flash(:error, "Not saved: #{message}")}
  end

  def handle_async(:check_registry, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(:checking, false) |> put_flash(:error, "Check failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp expiring?(%{registry_token_expires_at: at}),
    do: DateTime.diff(at, DateTime.utc_now()) < 14 * 86_400

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Deployment</:breadcrumb>

      <.header>
        Deployment
        <:subtitle>How this Foreman is wired up.</:subtitle>
      </.header>

      <div class="grid gap-4 md:grid-cols-3">
        <.panel title="GitHub App">
          <%= if @github_app do %>
            <.badge color="emerald" dot>Connected</.badge>
            <p :if={@github_app[:slug]} class="mt-2 text-sm text-ink-2">
              <a
                href={"https://github.com/apps/#{@github_app.slug}"}
                class="font-medium text-accent-ink underline"
                target="_blank"
                rel="noopener"
              >{@github_app.slug}</a>
            </p>
          <% else %>
            <.badge color="amber" dot>Not set up</.badge>
            <p class="mt-2 text-sm text-ink-2">
              Run setup, or set FOREMAN_GITHUB_* in the environment.
            </p>
          <% end %>
        </.panel>
        <.panel title="Tailscale">
          <.badge :if={@tailscale} color="emerald" dot>Connected</.badge>
          <.badge :if={not @tailscale} color="amber" dot>Off</.badge>
          <p class="mt-2 text-sm text-ink-2">
            {if @tailscale,
              do: "Environments join the tailnet tagged #{Enum.join(Tailscale.base_tags(), ", ")}.",
              else:
                "Set FOREMAN_TAILSCALE_CLIENT_ID and _SECRET (an OAuth client with auth_keys and devices:core) to join environments to the tailnet."}
          </p>
        </.panel>
        <.panel title="Database">
          <.badge>{if Foreman.Repo.sqlite?(), do: "SQLite", else: "Postgres"}</.badge>
          <p class="mt-2 text-sm text-ink-2">
            Environments are named {if Foreman.Config.slug_style() == :team,
              do: "<repo>-<login>-<n>",
              else: "<repo>-<n>"}.
          </p>
        </.panel>
      </div>

      <div :for={owner <- @owners} id={"owner-#{owner.id}"} class="space-y-4">
        <h2 class="pt-2 text-sm font-semibold text-ink">{owner.login}</h2>

        <.panel title="Container registry credential">
          <:subtitle>
            For private devcontainer images and features. GHCR only accepts classic personal access tokens: use a machine user's, with only read:packages. See docs/setup/ghcr-machine-user.md.
          </:subtitle>
          <%= if @registry_owner && @registry_owner.id == owner.id do %>
            <.form
              for={@registry_form}
              id="registry-form"
              phx-submit="save_registry"
              class="space-y-3"
            >
              <div class="grid gap-3 sm:grid-cols-2">
                <.input field={@registry_form[:host]} label="Registry" />
                <.input field={@registry_form[:username]} label="Machine user" />
              </div>
              <.input
                field={@registry_form[:token]}
                type="password"
                label="Classic token (read:packages)"
                autocomplete="off"
              />
              <div class="flex gap-2">
                <.button type="submit" variant="primary" size="sm" disabled={@checking}>{if @checking,
                  do: "Checking…",
                  else: "Check and save"}</.button>
                <.button type="button" size="sm" variant="ghost" phx-click="cancel_registry">Cancel</.button>
              </div>
            </.form>
          <% else %>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="text-sm">
                <p :if={owner.registry_token} class="text-ink">
                  {owner.registry_username} on {owner.registry_host}
                  <span
                    :if={owner.registry_token_expires_at}
                    class={["ml-1", expiring?(owner) && "font-medium text-warning"]}
                  >
                    · expires {Calendar.strftime(owner.registry_token_expires_at, "%b %-d, %Y")}
                  </span>
                </p>
                <p :if={is_nil(owner.registry_token)} class="text-ink-3">None set.</p>
              </div>
              <.button size="sm" phx-click="edit_registry" phx-value-id={owner.id}>{if owner.registry_token,
                do: "Replace",
                else: "Add"}</.button>
            </div>
          <% end %>
        </.panel>

        <.live_component
          module={ForemanWeb.SecretsComponent}
          id={"owner-secrets-#{owner.id}"}
          title="Owner secrets"
          description={"Every environment of a #{owner.login} repo gets these. Repo, user and environment secrets override them."}
          scope_name="owner"
          subject={owner}
          current_scope={@current_scope}
        />
      </div>

      <.panel title="Agent releases" padded={false}>
        <:subtitle>Signed by CI. Set a box's desired version to roll it out.</:subtitle>
        <ul :if={@releases != []} class="divide-y divide-line">
          <li :for={r <- @releases} class="flex items-center justify-between px-5 py-2.5 text-sm">
            <span class="font-medium text-ink">{r.version}</span>
            <span class="font-mono text-xs text-ink-3">{r.target} · {String.slice(r.sha256, 0, 12)}</span>
          </li>
        </ul>
        <p :if={@releases == []} class="px-5 py-4 text-sm text-ink-3">
          None yet. Publish one with <code class="font-mono">bin/foreman eval 'Foreman.Release.publish_agent(...)'</code>.
        </p>
      </.panel>
    </Layouts.app>
    """
  end
end
