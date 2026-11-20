defmodule ForemanWeb.RepoLive.Show do
  @moduledoc """
  One repo: its environments, your git identity and dotfiles overrides
  for it, which of your own devcontainer features go on it, and (admins)
  its token scope, Tailscale tags, default limits, repo-level secrets and
  prebuilds.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Boxes, Environments, Prebuilds, Repos, Scope}
  alias Foreman.Repos.TokenPermissions
  alias ForemanProtocol.Feature

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    repo = Repos.get_repo!(id)
    user = socket.assigns.current_scope.user
    setting = Accounts.get_repo_setting(user, repo)
    admin? = Scope.admin?(socket.assigns.current_scope)
    if admin? and connected?(socket), do: Prebuilds.subscribe(repo.id)

    {:ok,
     socket
     |> assign(:repo, repo)
     |> assign(:disabled_features, disabled_features(setting))
     |> assign(:page_title, repo.full_name)
     |> assign(:settings_form, to_form(settings_params(repo), as: :settings))
     |> assign(:token_choices, Repos.Repo.permissions(repo))
     |> assign(
       :override_form,
       to_form(override_params(setting), as: :override)
     )
     |> assign(
       :environments,
       Environments.list_environments(socket.assigns.current_scope)
       |> Enum.filter(&(&1.repo_id == repo.id))
     )
     |> assign_prebuilds(admin?)}
  end

  defp assign_prebuilds(socket, admin? \\ true)
  defp assign_prebuilds(socket, false), do: assign(socket, prebuild_boxes: [], prebuilds: %{})

  defp assign_prebuilds(socket, true) do
    socket
    |> assign(:prebuild_boxes, Boxes.list_boxes(socket.assigns.current_scope))
    |> assign(:prebuilds, Prebuilds.by_box(socket.assigns.repo))
  end

  defp settings_params(repo) do
    %{
      "token_mode" => repo.token_mode,
      "extra_repos" => Enum.join(repo.extra_repos, ", "),
      "tailscale_tags" => Enum.join(repo.tailscale_tags, ", "),
      "cpu_limit" => repo.cpu_limit,
      "memory_limit_mb" => repo.memory_limit_mb,
      "default_branch" => repo.default_branch
    }
  end

  defp disabled_features(nil), do: []
  defp disabled_features(setting), do: setting.disabled_features || []

  defp user_features(scope),
    do: (scope.user.devcontainer_features || %{}) |> Map.keys() |> Enum.sort()

  defp override_params(nil),
    do: %{
      "git_name" => "",
      "git_email" => "",
      "dotfiles_repository" => "",
      "dotfiles_install_command" => "",
      "dotfiles_target_path" => ""
    }

  defp override_params(s),
    do:
      Map.new(
        [
          :git_name,
          :git_email,
          :dotfiles_repository,
          :dotfiles_install_command,
          :dotfiles_target_path
        ],
        &{Atom.to_string(&1), Map.get(s, &1)}
      )

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Repos.update_repo_settings(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> assign(:repo, Repos.get_repo!(repo.id))
         |> assign(:settings_form, to_form(settings_params(repo), as: :settings))
         |> assign(:token_choices, Repos.Repo.permissions(repo))
         |> put_flash(
           :info,
           "Saved. Running environments get a token with the new scope when they next start, or within four hours. New limits apply when an environment is rebuilt."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:settings_form, to_form(%{changeset | action: :update}, as: :settings))
         |> assign(
           :token_choices,
           TokenPermissions.choices(params["token_permissions"] || socket.assigns.token_choices)
         )}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
  end

  def handle_event("save_override", %{"override" => params}, socket) do
    case Accounts.put_repo_setting(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, setting} ->
        Environments.push_secrets(user_id: socket.assigns.current_scope.user.id)

        {:noreply,
         socket
         |> assign(:override_form, to_form(override_params(setting), as: :override))
         |> put_flash(
           :info,
           "Saved. Git identity applies now. Dotfiles changes apply the next time dotfiles are installed."
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :override_form, to_form(%{changeset | action: :update}, as: :override))}
    end
  end

  # The boxes left ticked are the features that stay on. Anything of the
  # user's not among them is off here.
  def handle_event("save_features", %{"repo_features" => params}, socket) do
    on = List.wrap(params["on"])

    disabled =
      socket.assigns.current_scope
      |> user_features()
      |> Enum.map(&Feature.base/1)
      |> Enum.reject(&(&1 in on))

    case Accounts.put_repo_setting(socket.assigns.current_scope, socket.assigns.repo, %{
           "disabled_features" => disabled
         }) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:disabled_features, disabled_features(setting))
         |> put_flash(:info, "Saved. Features change on each environment's next rebuild.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't save that.")}
    end
  end

  def handle_event("build_prebuild", %{"box" => box_id}, socket) do
    with %{} = box <- Boxes.get_box(box_id),
         {:ok, _} <- Prebuilds.build(socket.assigns.current_scope, socket.assigns.repo, box) do
      {:noreply,
       socket
       |> assign_prebuilds()
       |> put_flash(:info, "Building a prebuild on #{box.name}.")}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_prebuild", %{"id" => id}, socket) do
    with %{} = prebuild <- Prebuilds.get(socket.assigns.repo, id),
         :ok <- Prebuilds.delete(socket.assigns.current_scope, prebuild) do
      {:noreply, assign_prebuilds(socket)}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:prebuild, _id}, socket), do: {:noreply, assign_prebuilds(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/repos"}>Repos</:breadcrumb>
      <:breadcrumb>{@repo.full_name}</:breadcrumb>
      <:actions>
        <.button
          :if={@repo.devcontainer_path}
          navigate={~p"/environments/new?repo_id=#{@repo.id}"}
          variant="primary"
          size="sm"
          icon="hero-plus"
        >
          New environment
        </.button>
      </:actions>

      <.header>
        {@repo.full_name}
        <:subtitle>
          <span :if={@repo.devcontainer_path} class="font-mono">{@repo.devcontainer_path}</span>
          <span :if={is_nil(@repo.devcontainer_path)}>No devcontainer found.</span>
        </:subtitle>
      </.header>

      <.callout :if={@repo.devcontainer_error} kind="warning">{@repo.devcontainer_error}</.callout>

      <div class="grid items-start gap-6 lg:grid-cols-2">
        <.panel title="Environments">
          <ul :if={@environments != []} class="-m-5 divide-y divide-line">
            <li
              :for={env <- @environments}
              class="flex items-center justify-between gap-2 px-5 py-2.5"
            >
              <.link
                navigate={~p"/environments/#{env.id}"}
                class="font-mono text-sm font-medium text-ink hover:text-accent-ink"
              >{env.slug}</.link>
              <.state_badge state={env.observed_state} size="sm" />
            </li>
          </ul>
          <p :if={@environments == []} class="text-sm text-ink-3">None of yours.</p>
        </.panel>

        <.panel title="Your git identity and dotfiles here">
          <:subtitle>
            Overrides your defaults for this repo only. Empty fields use the defaults from Settings.
          </:subtitle>
          <.form for={@override_form} id="override-form" phx-submit="save_override" class="space-y-3">
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@override_form[:git_name]}
                label="Git name"
                placeholder={@current_scope.user.git_name || @current_scope.user.name}
              />
              <.input
                field={@override_form[:git_email]}
                label="Git email"
                placeholder={@current_scope.user.git_email}
              />
            </div>
            <.input
              field={@override_form[:dotfiles_repository]}
              label="Dotfiles repo"
              placeholder={
                @current_scope.user.dotfiles_repository || "https://github.com/you/dotfiles.git"
              }
            />
            <.input
              field={@override_form[:dotfiles_install_command]}
              label="Dotfiles install command"
              placeholder="./install.sh"
            />
            <.input
              field={@override_form[:dotfiles_target_path]}
              label="Clone dotfiles to"
              placeholder={@current_scope.user.dotfiles_target_path || "~/dotfiles"}
            />
            <.button type="submit" size="sm">Save</.button>
          </.form>
          <p :if={user_features(@current_scope) == []} class="mt-4 text-xs text-ink-3">
            You can add your own devcontainer features in <.link
              navigate={~p"/settings"}
              class="underline"
            >Settings</.link>.
          </p>
        </.panel>

        <.panel :if={user_features(@current_scope) != []} title="Your devcontainer features here">
          <:subtitle>
            From your Settings. Untick one to leave it out of your environments of this repo. Changes apply on the next rebuild.
          </:subtitle>
          <.form
            for={%{}}
            as={:repo_features}
            id="repo-features"
            phx-submit="save_features"
            class="space-y-3"
          >
            <input type="hidden" name="repo_features[on][]" value="" />
            <label
              :for={ref <- user_features(@current_scope)}
              class="flex items-center gap-2 font-mono text-sm text-ink"
            >
              <input
                type="checkbox"
                class="checkbox"
                name="repo_features[on][]"
                value={Feature.base(ref)}
                checked={Feature.base(ref) not in @disabled_features}
              />
              {ref}
            </label>
            <.button type="submit" size="sm">Save</.button>
          </.form>
        </.panel>
      </div>

      <.panel :if={Scope.admin?(@current_scope)} title="Repo settings">
        <.form for={@settings_form} id="repo-settings" phx-submit="save_settings" class="space-y-4">
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@settings_form[:token_mode]}
              type="select"
              label="Environment GitHub token"
              options={[
                {"Scoped to this repo (recommended)", "scoped"},
                {"The user's own token (broad)", "broad"}
              ]}
            />
            <.input field={@settings_form[:default_branch]} label="Default branch" />
          </div>
          <.token_permissions
            choices={@token_choices}
            granted={@repo.owner.installation_permissions}
            owner={@repo.owner.login}
          />
          <.input
            field={@settings_form[:extra_repos]}
            label="Extra repos the scoped token can reach"
            placeholder="shared-config, design-system"
          />
          <p
            :if={@repo.owner.extra_repos != []}
            id="owner-extra-repos"
            class="-mt-2 text-xs text-ink-3"
          >
            It also reaches <span class="font-mono">{Enum.join(@repo.owner.extra_repos, ", ")}</span>, set for every {@repo.owner.login} repo in <.link
              navigate={~p"/admin"}
              class="underline"
            >Deployment</.link>.
          </p>
          <.input
            field={@settings_form[:tailscale_tags]}
            label="Extra Tailscale tags"
            placeholder="tag:staging-access"
          />
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@settings_form[:cpu_limit]}
              type="number"
              step="0.5"
              label="Default CPU limit"
              placeholder="None"
            />
            <.input
              field={@settings_form[:memory_limit_mb]}
              type="number"
              step="256"
              label="Default memory limit (MB)"
              placeholder="None"
            />
          </div>
          <.button type="submit" size="sm">Save settings</.button>
        </.form>
      </.panel>

      <.panel
        :if={Scope.admin?(@current_scope)}
        id="prebuilds"
        title="Prebuilds"
        padded={false}
      >
        <:subtitle>
          A new environment of {@repo.default_branch} on a box with a ready prebuild starts from it, with the clone and the devcontainer's images already there. Build again after the devcontainer changes.
        </:subtitle>
        <ul class="divide-y divide-line">
          <.prebuild_box
            :for={box <- @prebuild_boxes}
            box={box}
            repo={@repo}
            prebuilds={@prebuilds[box.id] || []}
          />
        </ul>
        <p :if={@prebuild_boxes == []} class="px-5 py-4 text-sm text-ink-3">No boxes yet.</p>
      </.panel>

      <.live_component
        :if={Scope.admin?(@current_scope)}
        module={ForemanWeb.SecretsComponent}
        id="repo-secrets"
        title="Repo secrets"
        description="Every environment of this repo gets these. User and environment secrets override them."
        scope_name="repo"
        subject={@repo}
        current_scope={@current_scope}
      />
    </Layouts.app>
    """
  end

  # A box's prebuilds of the repo (`Prebuilds.by_box/1`): the one new
  # environments start from, any ready ones they won't, and the latest
  # attempt when it's none of those.
  attr :box, :map, required: true
  attr :repo, :map, required: true
  attr :prebuilds, :list, required: true

  defp prebuild_box(assigns) do
    assigns = assign(assigns, :vm, Boxes.check_vm(assigns.box))

    ~H"""
    <li id={"prebuild-#{@box.id}"} class="px-5 py-3">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="text-sm font-medium text-ink">{@box.name}</div>
          <div :if={@vm != :ok} class="mt-0.5 text-xs text-ink-3">{elem(@vm, 1)}</div>
          <div :if={@vm == :ok and @prebuilds == []} class="mt-0.5 text-xs text-ink-3">None</div>
        </div>
        <.button
          :if={@vm == :ok}
          size="sm"
          phx-click="build_prebuild"
          phx-value-box={@box.id}
          disabled={Enum.any?(@prebuilds, &(&1.status == "building"))}
        >
          {if @prebuilds == [], do: "Build", else: "Rebuild"}
        </.button>
      </div>
      <ul :if={@prebuilds != []} class="mt-2 space-y-1.5">
        <li
          :for={prebuild <- @prebuilds}
          id={"prebuild-row-#{prebuild.id}"}
          class="flex flex-wrap items-center justify-between gap-2"
        >
          <.prebuild_status
            prebuild={prebuild}
            repo={@repo}
            unused={Prebuilds.unused_because(@repo, prebuild)}
          />
          <.button
            :if={prebuild.status != "building"}
            size="sm"
            phx-click="delete_prebuild"
            phx-value-id={prebuild.id}
            data-confirm={
              if prebuild.status == "ready" and is_nil(Prebuilds.unused_because(@repo, prebuild)),
                do: "Delete this prebuild? New environments on #{@box.name} will build from scratch.",
                else: "Delete this prebuild?"
            }
          >
            Delete
          </.button>
        </li>
      </ul>
    </li>
    """
  end

  attr :prebuild, :map, required: true
  attr :repo, :map, required: true
  attr :unused, :any, default: nil

  defp prebuild_status(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 gap-y-1 text-xs text-ink-3">
      <%= case {@prebuild.status, @unused} do %>
        <% {"building", _} -> %>
          <.badge color="amber" size="sm" dot pulse>Building</.badge>
          <span>{@prebuild.branch}</span>
        <% {"ready", nil} -> %>
          <.badge color="emerald" size="sm" dot>Ready</.badge>
          <span>{@prebuild.branch}</span>
          <span :if={@prebuild.size_mb}>{size(@prebuild.size_mb)}</span>
          <span :if={@prebuild.built_at}>
            built
            <.local_time
              id={"prebuild-#{@prebuild.id}-at"}
              at={@prebuild.built_at}
              format="relative"
            />
          </span>
        <% {"ready", {:branch, branch}} -> %>
          <.badge size="sm" dot>Not used</.badge>
          <span>
            Built from {branch}, the old default branch: new environments of {@repo.default_branch} won't start from it.
          </span>
          <span :if={@prebuild.size_mb}>{size(@prebuild.size_mb)}</span>
        <% {"ready", {:config, path}} -> %>
          <.badge size="sm" dot>Not used</.badge>
          <span class="break-all">
            Built for <span class="font-mono">{path}</span>, the old devcontainer config: new environments won't start from it.
          </span>
          <span :if={@prebuild.size_mb}>{size(@prebuild.size_mb)}</span>
        <% _failed -> %>
          <.badge color="rose" size="sm" dot>Failed</.badge>
          <span class="break-all">{@prebuild.error}</span>
      <% end %>
    </div>
    """
  end

  defp size(mb) when mb >= 1024, do: :erlang.float_to_binary(mb / 1024, decimals: 1) <> " GB"
  defp size(mb), do: "#{mb} MB"

  attr :choices, :map, required: true
  attr :granted, :map, default: nil
  attr :owner, :string, required: true

  defp token_permissions(assigns) do
    assigns =
      assign(
        assigns,
        :short,
        for(
          {name, _label, _levels} <- TokenPermissions.catalog(),
          TokenPermissions.short?(name, assigns.choices[name], assigns.granted),
          do: name
        )
      )

    ~H"""
    <fieldset id="token-permissions">
      <legend class="label">What the scoped token can do</legend>
      <p class="mb-3 text-xs text-ink-3">
        On this repo and its extra repos, its owner's included. Metadata (read) is always included. The broad token ignores these.
      </p>
      <div class="grid gap-x-8 gap-y-2 sm:grid-cols-2">
        <div
          :for={{name, label, _levels} <- TokenPermissions.catalog()}
          id={"permission-#{name}"}
          class="flex items-center justify-between gap-3"
        >
          <label
            for={"token-permission-#{name}"}
            class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-ink"
          >
            {label}
            <.badge :if={name in @short} color="amber" size="sm" data-role="not-granted">
              App lacks it
            </.badge>
          </label>
          <div class="relative w-28 shrink-0">
            <select
              id={"token-permission-#{name}"}
              name={"settings[token_permissions][#{name}]"}
              class="input h-8 text-sm"
            >
              {Phoenix.HTML.Form.options_for_select(
                Enum.map(TokenPermissions.levels(name), &{String.capitalize(&1), &1}),
                @choices[name]
              )}
            </select>
            <.icon
              name="hero-chevron-up-down-micro"
              class="pointer-events-none absolute right-2.5 top-1/2 size-4 -translate-y-1/2 text-ink-3"
            />
          </div>
        </div>
      </div>
      <p :if={@short != []} class="mt-3 text-xs text-warning">
        The GitHub App's installation on {@owner} doesn't have the flagged permissions, so tokens leave them out (or get read only). Add them to the App's permissions on GitHub and accept them on the installation; Foreman picks them up at the next sync.
      </p>
    </fieldset>
    """
  end
end
