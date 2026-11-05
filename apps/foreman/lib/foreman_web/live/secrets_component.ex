defmodule ForemanWeb.SecretsComponent do
  @moduledoc """
  Manages the secrets at one scope (owner, repo, user or environment).
  Values are write-only: the list shows names and who changed them last,
  and a value can be replaced or deleted but never shown.
  """
  use ForemanWeb, :live_component

  import ForemanWeb.ForemanComponents

  alias Foreman.Secrets

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
            class="flex items-center gap-3 px-5 py-2.5"
          >
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
      </.panel>
    </div>
    """
  end

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

  def handle_event("delete", %{"name" => name}, socket) do
    %{current_scope: scope, scope_name: scope_name, subject: subject} = socket.assigns
    Secrets.delete_secret(scope, scope_name, subject, name)
    send(self(), {:secret_deleted, name})
    {:noreply, assign(socket, :secrets, list_secrets(socket))}
  end

  defp list_secrets(socket) do
    {:ok, secrets} =
      Secrets.list_secrets(
        socket.assigns.current_scope,
        socket.assigns.scope_name,
        socket.assigns.subject
      )

    secrets
  end
end
