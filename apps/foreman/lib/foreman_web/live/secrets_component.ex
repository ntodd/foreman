defmodule ForemanWeb.SecretsComponent do
  @moduledoc """
  Manages the secrets at one scope (owner, repo, user or environment).
  Values are write-only: the list shows names and who changed them last,
  and a value can be replaced or deleted but never shown. Below that, the
  names the scope picks up from the scopes above it, read-only.
  """
  use ForemanWeb, :live_component

  import ForemanWeb.ForemanComponents

  alias Foreman.{Scope, Secrets}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok, secrets} =
      Secrets.list_secrets(
        socket.assigns.current_scope,
        socket.assigns.scope_name,
        socket.assigns.subject
      )

    {:ok,
     socket
     |> assign(:secrets, secrets)
     |> assign(:inherited, list_inherited_secrets(socket))
     |> assign_new(:repos, fn -> [] end)
     |> assign_new(:description, fn -> nil end)
     |> assign_new(:form, fn -> blank_form(socket) end)
     |> assign_new(:editing, fn -> nil end)}
  end

  # A page can hold several of these (one per owner on Deployment): the
  # component's id keeps their inputs' ids apart.
  defp secret_form(socket, data),
    do: to_form(data, as: :secret, id: "#{socket.assigns.id}-secret")

  defp blank_form(socket),
    do: secret_form(socket, %{"name" => "", "value" => "", "repo_ids" => []})

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.panel title={@title}>
        <:subtitle :if={@description}>{@description}</:subtitle>

        <ul
          :if={@secrets != []}
          id={"#{@id}-list"}
          class="-mx-5 -mt-5 mb-5 divide-y divide-line border-b border-line"
        >
          <li
            :for={secret <- @secrets}
            id={"#{@id}-#{secret.name}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-5 py-2.5"
          >
            <%!-- On a phone the buttons wrap under the name rather than squeezing it. --%>
            <div class="flex min-w-40 flex-1 items-center gap-3">
              <.icon name="hero-key-mini" class="size-4 shrink-0 text-ink-3" />
              <div class="min-w-0 flex-1">
                <p class="break-all font-mono text-[13px] font-medium text-ink">{secret.name}</p>
                <p class="text-xs text-ink-3">
                  <span :if={secret.repo_ids != []}>{repo_names(secret.repo_ids, @repos)} · </span>
                  Updated {Calendar.strftime(secret.updated_at, "%b %-d, %Y")}<span :if={
                    secret.updated_by
                  }> by {secret.updated_by.login}</span>
                </p>
              </div>
            </div>
            <%!-- Small screens place the menu against these buttons, so it stays on screen. --%>
            <div class="relative ml-auto flex items-center gap-3">
              <.dropdown
                :if={promote_targets(@scope_name, @subject, @current_scope) != []}
                id={"#{@id}-#{secret.name}-promote"}
                label="Move up"
                class="max-sm:static"
              >
                <.dropdown_item
                  :for={
                    {to, title, description} <- promote_targets(@scope_name, @subject, @current_scope)
                  }
                  id={"#{@id}-#{secret.name}-promote-#{to}"}
                  title={title}
                  icon="hero-arrow-up-mini"
                  phx-click={
                    JS.push("promote", value: %{name: secret.name, to: to}, target: @myself)
                    |> hide_dropdown("#{@id}-#{secret.name}-promote")
                  }
                  data-confirm={"Move #{secret.name} to #{target_name(to, @subject)}? It leaves this environment, and the value moves without being shown."}
                >
                  {description}
                </.dropdown_item>
              </.dropdown>
              <.button
                size="sm"
                variant="ghost"
                phx-click="edit"
                phx-value-name={secret.name}
                phx-target={@myself}
              >
                Replace
              </.button>
              <.icon_button
                icon="hero-trash"
                label={"Delete #{secret.name}"}
                size="sm"
                phx-click="delete"
                phx-value-name={secret.name}
                phx-target={@myself}
                data-confirm={"Delete #{secret.name}? Running environments get the change right away."}
              />
            </div>
          </li>
        </ul>

        <p :if={@secrets == []} class="mb-5 text-sm text-ink-3">No secrets here yet.</p>

        <.form for={@form} id={"#{@id}-form"} phx-submit="save" phx-target={@myself} class="space-y-3">
          <div class="grid gap-3 sm:grid-cols-[minmax(0,14rem)_minmax(0,1fr)]">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="API_KEY"
              autocomplete="off"
              class="input font-mono"
              spellcheck="false"
            />
            <.input
              field={@form[:value]}
              type="textarea"
              label={if @editing, do: "New value for #{@editing}", else: "Value"}
              placeholder="Stored encrypted; can't be shown again"
              autocomplete="off"
              spellcheck="false"
              class="input min-h-[2.25rem] font-mono placeholder:font-sans"
              rows="1"
            />
          </div>
          <.input
            :if={@scope_name == "user" and repo_options(@repos, @form) != []}
            field={@form[:repo_ids]}
            type="select"
            multiple
            label="Only for these repos (leave empty for all)"
            options={repo_options(@repos, @form)}
          />
          <div class="flex items-center gap-2">
            <.button type="submit" variant="primary" size="sm">{if @editing,
              do: "Replace value",
              else: "Add secret"}</.button>
            <.button
              :if={@editing}
              type="button"
              size="sm"
              variant="ghost"
              phx-click="cancel"
              phx-target={@myself}
            >Cancel</.button>
          </div>
        </.form>

        <%!-- Two hyphens: a secret's name can't have one, so its row's id
             can't collide with this. --%>
        <div
          :if={@inherited != []}
          id={"#{@id}--inherited"}
          class="-mx-5 -mb-5 mt-5 border-t border-line"
        >
          <p class="px-5 pt-3 text-xs font-medium text-ink-2">
            Inherited from higher levels
          </p>
          <ul class="divide-y divide-line">
            <li
              :for={secret <- @inherited}
              id={"#{@id}--inherited-#{secret.scope}-#{secret.name}"}
              class="flex items-center gap-3 px-5 py-2"
            >
              <.icon name="hero-key-mini" class="size-4 shrink-0 text-ink-3" />
              <p class="min-w-0 flex-1 break-all font-mono text-[13px] text-ink-2">{secret.name}</p>
              <.badge size="sm">{level_label(secret.scope)}</.badge>
            </li>
          </ul>
        </div>
      </.panel>
    </div>
    """
  end

  # Where an environment's secret can move to, for its owner: their own
  # secrets, and the repo's if they're an admin.
  defp promote_targets("environment", %{user_id: owner_id} = env, scope) do
    [
      Scope.user_id(scope) == owner_id &&
        {"user", "Your secrets",
         "For your environments of #{env.repo.full_name}. Your other repos don't get it."},
      (Scope.user_id(scope) == owner_id and Scope.admin?(scope)) &&
        {"repo", "#{env.repo.full_name}'s secrets",
         "For every environment of #{env.repo.full_name}, everyone's. Their own secrets still override it."}
    ]
    |> Enum.filter(& &1)
  end

  defp promote_targets(_scope_name, _subject, _scope), do: []

  # The repos a secret can be limited to, plus any it's limited to that
  # aren't listed any more (no devcontainer now, or gone). Without an
  # option those can't stay selected, and a Replace that sends no repos
  # widens the secret to every repo.
  defp repo_options(repos, form) do
    listed = Enum.map(repos, &{&1.full_name, &1.id})
    known = MapSet.new(repos, & &1.id)

    unlisted =
      case List.wrap(form[:repo_ids].value) |> Enum.reject(&(&1 in ["", nil] or &1 in known)) do
        [] ->
          []

        ids ->
          names = Foreman.Repos.full_names(ids)
          Enum.map(ids, &{"#{names[&1] || "A removed repo"} (not listed)", &1})
      end

    listed ++ unlisted
  end

  defp level_label("owner"), do: "Owner"
  defp level_label("repo"), do: "Repo"
  defp level_label("user"), do: "User"

  defp repo_names(ids, repos) do
    repos
    |> Enum.filter(&(&1.id in ids))
    |> Enum.map_join(", ", & &1.full_name)
    |> then(&if(&1 == "", do: "selected repos", else: &1))
  end

  @impl true
  def handle_event("save", %{"secret" => params}, socket) do
    params =
      Map.update(params, "repo_ids", [], fn ids ->
        ids |> List.wrap() |> Enum.reject(&(&1 == ""))
      end)

    %{current_scope: scope, scope_name: scope_name, subject: subject} = socket.assigns

    case Secrets.put_secret(scope, scope_name, subject, params) do
      {:ok, secret} ->
        send(self(), {:secret_saved, secret.name})

        {:noreply,
         socket
         |> assign(:editing, nil)
         |> assign(:form, blank_form(socket))
         |> assign(:secrets, list_secrets(socket))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, secret_form(socket, %{changeset | action: :insert}))}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
  end

  # Starts from the secret's current repos, so replacing the value doesn't
  # quietly widen it to every repo.
  def handle_event("edit", %{"name" => name}, socket) do
    repo_ids =
      case Enum.find(socket.assigns.secrets, &(&1.name == name)) do
        %{repo_ids: ids} -> ids
        nil -> []
      end

    {:noreply,
     socket
     |> assign(:editing, name)
     |> assign(
       :form,
       secret_form(socket, %{"name" => name, "value" => "", "repo_ids" => repo_ids})
     )}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:form, blank_form(socket))}
  end

  def handle_event("promote", %{"name" => name, "to" => to}, socket) do
    %{current_scope: scope, subject: env} = socket.assigns

    # A component's flash only reaches the page on a redirect, so the page
    # shows it.
    message =
      case Secrets.promote_secret(scope, env, name, to) do
        {:ok, _secret} ->
          {:info, "Moved #{name} to #{target_name(to, env)}."}

        {:error, :exists} ->
          {:error, "#{already_has(to, env)} a secret named #{name}. Delete one of them first."}

        {:error, :overridden} ->
          {:error,
           "#{env.user.login}'s own #{name} would override it here, so #{name} stays on this environment."}

        {:error, :not_found} ->
          {:error, "#{name} changed or went while you were moving it. Have another look."}

        {:error, _} ->
          {:error, "Couldn't move #{name}."}
      end

    send(self(), {:secret_promoted, message})

    # A moved secret is now one this environment inherits.
    {:noreply,
     socket
     |> assign(:secrets, list_secrets(socket))
     |> assign(:inherited, list_inherited_secrets(socket))}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    %{current_scope: scope, scope_name: scope_name, subject: subject} = socket.assigns
    Secrets.delete_secret(scope, scope_name, subject, name)
    send(self(), {:secret_deleted, name})
    {:noreply, assign(socket, :secrets, list_secrets(socket))}
  end

  defp target_name("user", _env), do: "your secrets"
  defp target_name("repo", env), do: "#{env.repo.full_name}'s secrets"

  defp already_has("user", _env), do: "You already have"
  defp already_has("repo", env), do: "#{env.repo.full_name} already has"

  defp list_secrets(socket) do
    {:ok, secrets} =
      Secrets.list_secrets(
        socket.assigns.current_scope,
        socket.assigns.scope_name,
        socket.assigns.subject
      )

    secrets
  end

  defp list_inherited_secrets(socket) do
    {:ok, inherited} =
      Secrets.list_inherited_secrets(
        socket.assigns.current_scope,
        socket.assigns.scope_name,
        socket.assigns.subject
      )

    inherited
  end
end
