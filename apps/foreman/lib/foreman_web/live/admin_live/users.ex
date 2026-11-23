defmodule ForemanWeb.AdminLive.Users do
  @moduledoc """
  People who've signed in: roles and access, and the devcontainer features
  each adds to their own environments (a feature runs code in them).
  """
  use ForemanWeb, :live_view

  alias Foreman.Accounts
  alias Foreman.Accounts.SSHRemovals

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_ssh_review()
    {:ok, socket |> assign(:page_title, "People") |> refresh()}
  end

  @impl true
  def handle_info(:refresh_ssh_removals, socket) do
    schedule_ssh_review()
    {:noreply, assign(socket, :ssh_removals, SSHRemovals.outstanding())}
  end

  defp schedule_ssh_review, do: Process.send_after(self(), :refresh_ssh_removals, 10_000)

  defp refresh(socket) do
    socket
    |> assign(:users, Accounts.list_users())
    |> assign(:ssh_removals, SSHRemovals.outstanding())
  end

  @impl true
  def handle_event("acknowledge_ssh", %{"id" => id}, socket) do
    respond(socket, SSHRemovals.acknowledge(socket.assigns.current_scope, id))
  end

  @impl true
  def handle_event("role", %{"id" => id, "role" => role}, socket) do
    respond(socket, Accounts.set_role(socket.assigns.current_scope, Accounts.get_user!(id), role))
  end

  def handle_event("disable", %{"id" => id, "disabled" => disabled}, socket) do
    respond(
      socket,
      Accounts.set_disabled(
        socket.assigns.current_scope,
        Accounts.get_user!(id),
        disabled == "true"
      )
    )
  end

  defp respond(socket, {:ok, _}),
    do: {:noreply, socket |> refresh() |> put_flash(:info, "Saved.")}

  defp respond(socket, {:error, :self}),
    do: {:noreply, put_flash(socket, :error, "You can't change your own access.")}

  defp respond(socket, {:error, :configured_admin}),
    do:
      {:noreply,
       put_flash(socket, :error, "Remove this login from FOREMAN_ADMINS to change its role.")}

  defp respond(socket, {:error, _}),
    do: {:noreply, put_flash(socket, :error, "Couldn't save that.")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="narrow"
    >
      <:breadcrumb>People</:breadcrumb>
      <.header>
        People
        <:subtitle>
          Everyone who has signed in. Who may sign in is set by FOREMAN_ADMINS, FOREMAN_ALLOWED_USERS and FOREMAN_ALLOWED_ORG.
        </:subtitle>
      </.header>

      <section
        :if={@ssh_removals != []}
        id="ssh-removals"
        class="mb-5 rounded-xl border border-line bg-raised p-5"
      >
        <h2 class="font-medium text-ink">Pending SSH access removal</h2>
        <p class="mt-2 text-sm text-ink-2">
          These identities may still open new SSH sessions. Ask your tailnet administrator to
          review their Tailscale identities, groups and tags, remove SSH access to Foreman
          environments, and verify that a new login is denied and admins can still connect.
          Tailscale policy changes can end active SSH sessions. Coordinate the change with session owners.
        </p>
        <ul class="mt-3 divide-y divide-line">
          <li
            :for={removal <- @ssh_removals}
            class="flex flex-wrap items-center justify-between gap-3 py-2"
          >
            <span class="break-all text-sm font-medium">{removal.login}<span
              :if={removal.name}
              class="text-ink-3"
            > · {removal.name}</span></span>
            <.button
              size="sm"
              variant="secondary"
              phx-click="acknowledge_ssh"
              phx-value-id={removal.id}
            >
              Acknowledge removal
            </.button>
          </li>
        </ul>
      </section>

      <section class="rounded-xl border border-line bg-raised shadow-xs">
        <ul class="divide-y divide-line">
          <li
            :for={user <- @users}
            id={"user-#{user.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-2 px-5 py-3"
          >
            <.avatar user={user} class="size-8 text-xs" />
            <%!-- The actions drop to their own line when there's no room. --%>
            <div class="min-w-0 flex-1 basis-32">
              <p class="truncate text-sm font-medium text-ink">{user.login}</p>
              <p class="truncate text-xs text-ink-3">
                {user.name}<span :if={user.github_login_expired}> · GitHub login expired</span><span :if={
                  user.disabled_at
                }> · disabled</span>
              </p>
              <p
                :for={{ref, options} <- Enum.sort(user.devcontainer_features || %{})}
                class="flex flex-wrap gap-x-1.5 font-mono text-xs text-ink-3"
                title="Devcontainer feature"
              >
                <span class="break-all">{ref}</span>
                <span :if={options != %{}} class="break-all">{JSON.encode!(options)}</span>
              </p>
            </div>
            <div class="ml-auto flex items-center gap-3">
              <.badge :if={user.role == "admin"} color="brand" size="sm">
                {if Accounts.configured_admin?(user.login),
                  do: "Admin · FOREMAN_ADMINS",
                  else: "Admin"}
              </.badge>
              <%= if user.id != @current_scope.user.id do %>
                <.button
                  :if={!Accounts.configured_admin?(user.login)}
                  size="sm"
                  variant="ghost"
                  phx-click="role"
                  phx-value-id={user.id}
                  phx-value-role={if user.role == "admin", do: "member", else: "admin"}
                >
                  {if user.role == "admin", do: "Make member", else: "Make admin"}
                </.button>
                <.button
                  size="sm"
                  variant={if user.disabled_at, do: "secondary", else: "danger_outline"}
                  phx-click="disable"
                  phx-value-id={user.id}
                  phx-value-disabled={to_string(is_nil(user.disabled_at))}
                >
                  {if user.disabled_at, do: "Enable", else: "Disable"}
                </.button>
              <% end %>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
