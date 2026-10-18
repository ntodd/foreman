defmodule ForemanWeb.EnvironmentLive.Show do
  @moduledoc """
  One environment: how to connect, its state and actions, the
  restart-now-or-later choice after a secrets change, its operations
  with live logs, its own secrets, and a destroy that checks git first.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Boxes, Capacity, Environments, Operations}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    env = Environments.get_environment!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Environments.subscribe(env.id)
      Phoenix.PubSub.subscribe(Foreman.PubSub, "boxes")
    end

    {:ok,
     socket
     |> assign(:env, env)
     |> assign(:page_title, env.slug)
     |> assign(:selected_op, nil)
     |> assign(:log, "")
     |> assign(:destroy_check, nil)
     |> assign(:later, false)
     |> assign(:sync, nil)
     |> assign(:sync_op, nil)
     |> assign(:loaded_state, nil)
     |> load()
     |> check_branch()}
  end

  # The page's own git status checks aren't activity anyone asked for.
  @unlisted ~w(git_status)

  defp load(socket) do
    env = Environments.get_environment!(socket.assigns.current_scope, socket.assigns.env.id)
    all_ops = Operations.list_for_environment(env.id, 15)
    ops = Operations.list_for_environment(env.id, 15, except: @unlisted)
    previous = socket.assigns.loaded_state

    socket
    |> assign(:env, env)
    |> assign(:loaded_state, env.observed_state)
    |> assign(:ops, ops)
    # A check that's holding up a Stop has to be cancellable too.
    |> assign(:in_progress, in_progress(all_ops))
    |> assign(:online, Boxes.online?(env.box_id))
    |> assign(:provisioned, Capacity.provisioned(env, env.repo))
    |> assign(:usage, Foreman.Capacity.Tracker.latest_usage(env.id))
    |> select_default_op()
    |> then(&if(came_up?(previous, env), do: check_branch(&1), else: &1))
  end

  defp came_up?(previous, env),
    do: previous not in [nil, "running"] and env.observed_state == "running"

  # Compares the clone with its branch on GitHub: the agent reports the
  # clone's HEAD, and branch_sync asks GitHub.
  defp check_branch(socket) do
    %{env: env, online: online, current_scope: scope} = socket.assigns

    with true <- connected?(socket) and online and env.observed_state == "running",
         true <- Foreman.GitHub.configured?(),
         {:ok, op} <- Environments.check_branch(scope, env) do
      Operations.subscribe(op.id)
      assign(socket, :sync_op, op.id)
    else
      _ -> socket
    end
  end

  # Follows the newest operation unless the reader picked one.
  defp select_default_op(%{assigns: %{selected_op: nil, ops: [op | _]}} = socket),
    do: watch_op(socket, op.id)

  defp select_default_op(socket), do: socket

  # The operation a Cancel button stops: the one on the box if there is
  # one, otherwise the next queued. `ops` is newest first.
  defp in_progress(ops) do
    Enum.find(ops, &(&1.status in ~w(dispatched running))) ||
      ops |> Enum.reverse() |> Enum.find(&(&1.status == "queued"))
  end

  defp watch_op(socket, op_id) do
    if connected?(socket) do
      if previous = socket.assigns.selected_op,
        do: Phoenix.PubSub.unsubscribe(Foreman.PubSub, "operation:" <> previous)

      Operations.subscribe(op_id)
    end

    op = Operations.get!(op_id)
    socket |> assign(:selected_op, op_id) |> assign(:log, Operations.log(op))
  end

  # -- events ------------------------------------------------------------------

  @impl true
  def handle_event("action", %{"do" => action}, socket) do
    %{current_scope: scope, env: env} = socket.assigns

    result =
      case action do
        "start" -> Environments.start(scope, env)
        "retry" -> Environments.retry(scope, env)
        "stop" -> Environments.stop(scope, env)
        "rebuild" -> Environments.rebuild(scope, env)
        "restart_affected" -> Environments.restart(scope, env, :affected)
        "restart_all" -> Environments.restart(scope, env, :all)
        "logs" -> Environments.logs(scope, env)
      end

    case result do
      {:ok, op} -> {:noreply, socket |> load() |> watch_op(op.id)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("later", _params, socket), do: {:noreply, assign(socket, :later, true)}

  def handle_event("cancel_op", %{"id" => id}, socket) do
    %{current_scope: scope, env: env} = socket.assigns

    case Environments.cancel_operation(scope, env, id) do
      {:ok, _op} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Only this environment's operations: the id comes from the client.
  def handle_event("select_op", %{"id" => id}, socket) do
    env_id = socket.assigns.env.id

    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Operations.get(id) do
          %{environment_id: ^env_id} -> {:noreply, watch_op(socket, id)}
          _ -> {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_destroy", _params, %{assigns: %{online: false}} = socket) do
    check = %{
      op_id: nil,
      status: :failed,
      result: %{"error" => "the box is offline"},
      confirm: ""
    }

    {:noreply, assign(socket, :destroy_check, check)}
  end

  def handle_event("check_destroy", _params, socket) do
    case Environments.git_status(socket.assigns.current_scope, socket.assigns.env) do
      {:ok, op} ->
        if connected?(socket), do: Operations.subscribe(op.id)

        {:noreply,
         assign(socket, :destroy_check, %{
           op_id: op.id,
           status: :checking,
           result: nil,
           confirm: ""
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("cancel_destroy", _params, socket),
    do: {:noreply, assign(socket, :destroy_check, nil)}

  def handle_event("confirm_input", %{"confirm" => value}, socket) do
    {:noreply, update(socket, :destroy_check, &%{&1 | confirm: value})}
  end

  def handle_event("destroy", _params, socket) do
    %{env: env, destroy_check: check} = socket.assigns

    if destroy_allowed?(check, env) do
      case Environments.destroy(socket.assigns.current_scope, env) do
        {:ok, _op} ->
          {:noreply,
           socket |> put_flash(:info, "Destroying #{env.slug}.") |> push_navigate(to: ~p"/")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  # A clean tree destroys with one click; anything that would be lost
  # (or a status we couldn't get) needs the slug typed out.
  defp destroy_allowed?(%{status: :done, result: %{"clean" => true}}, _env), do: true

  defp destroy_allowed?(%{status: status, confirm: confirm}, env) when status in [:done, :failed],
    do: confirm == env.slug

  defp destroy_allowed?(_, _), do: false

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(:unauthorized), do: "You can't do that to this environment."

  # -- live updates ----------------------------------------------------------------

  @impl true
  def handle_info({:op_log, op_id, data}, %{assigns: %{selected_op: op_id}} = socket) do
    {:noreply, update(socket, :log, &trim_log(&1 <> data))}
  end

  def handle_info({:op_log, _op_id, _data}, socket), do: {:noreply, socket}

  def handle_info({:operation, op}, socket) do
    finished? = Foreman.Operations.Operation.finished?(op)

    socket =
      socket
      |> then(&if(finished?, do: destroy_check_done(&1, op), else: &1))
      |> then(&if(finished?, do: branch_check_done(&1, op), else: &1))

    {:noreply, load(socket)}
  end

  def handle_info({:environment, _id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  # The destroy check and the page's own check can be the same operation:
  # a queued git status is shared.
  defp destroy_check_done(%{assigns: %{destroy_check: %{op_id: id}}} = socket, %{id: id} = op) do
    status = if op.status == "succeeded", do: :done, else: :failed

    update(
      socket,
      :destroy_check,
      &%{&1 | status: status, result: op.result || %{"error" => op.error}}
    )
  end

  defp destroy_check_done(socket, _op), do: socket

  defp branch_check_done(%{assigns: %{sync_op: id}} = socket, %{id: id} = op) do
    socket = assign(socket, :sync_op, nil)

    if op.status == "succeeded" and is_map(op.result) do
      env = socket.assigns.env
      start_async(socket, :branch_sync, fn -> Environments.branch_sync(env, op.result) end)
    else
      assign(socket, :sync, nil)
    end
  end

  defp branch_check_done(socket, _op), do: socket

  @impl true
  def handle_async(:branch_sync, {:ok, {:ok, sync}}, socket),
    do: {:noreply, assign(socket, :sync, sync)}

  def handle_async(:branch_sync, _result, socket), do: {:noreply, assign(socket, :sync, nil)}

  defp trim_log(log) when byte_size(log) > 400_000,
    do: binary_part(log, byte_size(log) - 300_000, 300_000)

  defp trim_log(log), do: log

  # -- view helpers --------------------------------------------------------------------

  defp tailscale?, do: Foreman.Tailscale.configured?()

  # <.link> only takes http(s) and a few other schemes as strings.
  defp vscode_url(env) do
    {:vscode, "//vscode-remote/ssh-remote+#{env.remote_user}@#{env.slug}#{env.workspace_folder}"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb navigate={~p"/"}>Environments</:breadcrumb>
      <:breadcrumb>{@env.slug}</:breadcrumb>

      <.header>
        <span class="font-mono">{@env.slug}</span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-x-2 gap-y-1">
            <.link navigate={~p"/repos/#{@env.repo.id}"} class="hover:text-ink">{@env.repo.full_name}</.link>
            <span class="text-ink-3">·</span>
            <span class="font-mono">{@env.branch}</span>
            <span :if={@sync} class="text-ink-3">·</span>
            <.branch_sync :if={@sync} sync={@sync} branch={@env.branch} />
            <span class="text-ink-3">·</span>
            <.link navigate={~p"/boxes/#{@env.box.id}"} class="hover:text-ink">{@env.box.name}</.link>
            <.badge :if={not @online} size="sm">Box offline</.badge>
          </span>
        </:subtitle>
        <:actions>
          <.state_badge state={@env.observed_state} />
          <.button
            :if={@env.created_once and @env.observed_state in ~w(stopped error missing partial)}
            phx-click="action"
            phx-value-do="start"
            icon="hero-play-mini"
            variant="primary"
            size="sm"
          >
            Start
          </.button>
          <.button
            :if={not @env.created_once and @env.observed_state == "error"}
            phx-click="action"
            phx-value-do="retry"
            icon="hero-arrow-path-mini"
            variant="primary"
            size="sm"
          >
            Retry
          </.button>
          <.button
            :if={@env.observed_state in ~w(running partial)}
            phx-click="action"
            phx-value-do="stop"
            icon="hero-stop-mini"
            size="sm"
          >
            Stop
          </.button>
          <.button
            phx-click="action"
            phx-value-do="rebuild"
            icon="hero-wrench-screwdriver-mini"
            size="sm"
            data-confirm={"Rebuild #{@env.slug}? Containers are recreated from a fresh build; the workspace, volumes and tailnet identity are kept."}
          >
            Rebuild
          </.button>
          <.button phx-click="check_destroy" icon="hero-trash-mini" size="sm" variant="danger_outline">Destroy</.button>
        </:actions>
      </.header>

      <%!-- Also after a failed stop or secrets write, which leave the state as it was. --%>
      <.callout
        :if={@env.status_message && not busy?(@env.observed_state)}
        kind="danger"
        id="env-error"
      >
        <p class="font-medium">The last operation failed.</p>
        <p class="mt-0.5 whitespace-pre-wrap break-words font-mono text-xs">{@env.status_message}</p>
      </.callout>

      <.callout :if={@env.pending_restart and not @later} kind="warning" id="pending-restart">
        <p class="font-medium">Secrets changed: {Enum.join(@env.pending_changes, ", ")}</p>
        <p class="mt-0.5">
          New shells already have them. Running processes keep the old values until a restart.
        </p>
        <:actions>
          <.button size="sm" phx-click="action" phx-value-do="restart_affected">Restart affected</.button>
          <.button size="sm" phx-click="action" phx-value-do="restart_all">Restart all</.button>
          <.button size="sm" variant="ghost" phx-click="later">Later</.button>
        </:actions>
      </.callout>

      <.callout :for={warning <- @env.warnings} kind="info" icon="hero-shield-exclamation-mini">
        {warning}
      </.callout>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div class="min-w-0 space-y-6">
          <.panel title="Connect" id="connect">
            <div :if={@env.remote_user} class="space-y-4">
              <.command
                :if={tailscale?()}
                id="ssh-command"
                label="SSH (Tailscale SSH, no keys needed)"
                command={"ssh #{@env.remote_user}@#{@env.slug}"}
              />
              <.command
                id="exec-command"
                label="On the box"
                command={"docker exec -it -u #{@env.remote_user} -w #{@env.workspace_folder} #{@env.slug}-#{@env.devcontainer_service}-1 bash -l"}
              />
              <div :if={tailscale?()} class="flex flex-wrap items-center gap-2">
                <.button href={vscode_url(@env)} size="sm" icon="hero-code-bracket-square-mini">Open in VS Code</.button>
                <span class="text-xs text-ink-3">Apps listen on
                <span class="font-mono">http://{@env.slug}:PORT</span>
                on the tailnet. Nothing publishes ports.</span>
              </div>
              <p :if={not tailscale?()} id="tailscale-off" class="text-xs text-ink-3">
                SSH and VS Code need the environment on your tailnet. Set
                <span class="font-mono">FOREMAN_TAILSCALE_CLIENT_ID</span>
                and <span class="font-mono">FOREMAN_TAILSCALE_CLIENT_SECRET</span>
                on Foreman, then rebuild.
              </p>
            </div>
            <p :if={is_nil(@env.remote_user)} class="text-sm text-ink-3">
              Connection details appear once the environment has started.
            </p>
          </.panel>

          <.live_component
            module={ForemanWeb.SecretsComponent}
            id="env-secrets"
            title="Secrets for this environment"
            description="These override owner, repo and your own secrets, for this environment only."
            scope_name="environment"
            subject={@env}
            current_scope={@current_scope}
          />
        </div>

        <aside class="space-y-6">
          <.panel title="Details">
            <dl class="space-y-2.5">
              <.fact term="Owner">{@env.user.login}</.fact>
              <.fact :if={@env.workspace_folder} term="Workspace">
                <span class="truncate font-mono text-xs">{@env.workspace_folder}</span>
              </.fact>
              <.fact :if={@env.services != []} term="Services">
                <span class="truncate text-right">{Enum.join(@env.services, ", ")}</span>
              </.fact>
              <.fact term="Created">
                <.local_time id="env-created" at={@env.inserted_at} format="date" />
              </.fact>
            </dl>
          </.panel>

          <.panel title="Resources">
            <dl class="space-y-2.5">
              <.fact term="CPU limit">{@env.cpu_limit || @env.repo.cpu_limit || "None"}</.fact>
              <.fact term="Memory limit">
                {if m = @env.memory_limit_mb || @env.repo.memory_limit_mb, do: "#{m} MB", else: "None"}
              </.fact>
              <.fact term="Counted as">
                {Float.round(@provisioned.cpus * 1.0, 1)} CPUs, {gib(@provisioned.memory_mb)} GiB
              </.fact>
              <.fact term="From">{provisioned_source(@provisioned.source)}</.fact>
              <.fact :if={@usage} term="Using now">
                {round(@usage.cpu_percent)}% CPU, {gib(@usage.memory_mb)} GiB
              </.fact>
            </dl>
          </.panel>
        </aside>
      </div>

      <.panel title="Activity" padded={false} id="activity">
        <:actions>
          <.button
            :if={@in_progress}
            id="cancel-op"
            size="sm"
            variant="ghost"
            phx-click="cancel_op"
            phx-value-id={@in_progress.id}
            data-confirm={"Cancel #{String.downcase(action_label(@in_progress.action))}? Foreman stops waiting on it; retry or rebuild the environment afterwards."}
            icon="hero-x-circle-mini"
          >Cancel {String.downcase(action_label(@in_progress.action))}</.button>
          <.button
            size="sm"
            variant="ghost"
            phx-click="action"
            phx-value-do="logs"
            icon="hero-document-text-mini"
          >Container logs</.button>
        </:actions>
        <div class="grid md:grid-cols-[15rem_minmax(0,1fr)]">
          <ul class="max-h-[28rem] divide-y divide-line overflow-y-auto border-b border-line md:border-b-0 md:border-r">
            <li :for={op <- @ops}>
              <button
                type="button"
                phx-click="select_op"
                phx-value-id={op.id}
                class={[
                  "block w-full px-4 py-2.5 text-left transition-colors hover:bg-subtle",
                  @selected_op == op.id && "bg-subtle"
                ]}
              >
                <span class="block truncate text-sm font-medium text-ink">{action_label(op.action)}</span>
                <span class="mt-0.5 flex items-center justify-between gap-2">
                  <.op_status status={op.status} />
                  <span class="text-xs text-ink-3">
                    <.local_time id={"op-time-#{op.id}"} at={op.inserted_at} format="relative" />
                  </span>
                </span>
              </button>
            </li>
            <li :if={@ops == []} class="px-4 py-6 text-sm text-ink-3">Nothing yet.</li>
          </ul>
          <pre id="op-log" phx-hook="LogTail" class="log-view h-[28rem] p-4 md:rounded-br-xl">{@log}<span :if={@log == ""} class="text-studio-ink-2">No output yet.</span></pre>
        </div>
      </.panel>

      <.modal :if={@destroy_check} id="destroy-modal" show on_cancel={JS.push("cancel_destroy")}>
        <h2 id="destroy-modal-title" class="text-lg font-semibold text-ink">Destroy {@env.slug}?</h2>
        <p class="mt-1 text-sm text-ink-2">
          Its containers, volumes and workspace are deleted from {@env.box.name}, and it leaves the tailnet. This can't be undone.
        </p>

        <div class="mt-5">
          <p
            :if={@destroy_check.status == :checking}
            class="flex items-center gap-2 text-sm text-ink-2"
          >
            <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
            Checking for unsaved work…
          </p>
          <.callout
            :if={@destroy_check.status == :done and @destroy_check.result["clean"]}
            kind="info"
            icon="hero-check-circle-mini"
          >
            The working tree is clean and every commit is pushed.
          </.callout>
          <.callout
            :if={@destroy_check.status == :done and not @destroy_check.result["clean"]}
            kind="danger"
          >
            {@destroy_check.result["changed_files"]} uncommitted {if @destroy_check.result[
                                                                       "changed_files"
                                                                     ] == 1,
                                                                     do: "change",
                                                                     else: "changes"} and {@destroy_check.result[
              "unpushed_commits"
            ]} unpushed {if @destroy_check.result["unpushed_commits"] == 1,
              do: "commit",
              else: "commits"} on {@destroy_check.result["branch"]} will be lost.
          </.callout>
          <.callout :if={@destroy_check.status == :failed} kind="warning">
            Couldn't check git status: {@destroy_check.result["error"]}
          </.callout>

          <form
            :if={
              @destroy_check.status in [:done, :failed] and
                not (@destroy_check.result["clean"] == true)
            }
            phx-change="confirm_input"
            class="mt-4"
          >
            <.input
              name="confirm"
              value={@destroy_check.confirm}
              label={"Type #{@env.slug} to confirm"}
              autocomplete="off"
            />
          </form>
        </div>

        <div class="mt-6 flex justify-end gap-2">
          <.button phx-click={JS.exec("data-cancel", to: "#destroy-modal")}>Cancel</.button>
          <.button
            variant="danger"
            phx-click="destroy"
            disabled={not destroy_allowed?(@destroy_check, @env)}
          >Destroy</.button>
        </div>
      </.modal>
    </Layouts.app>
    """
  end

  attr :sync, :map, required: true
  attr :branch, :string, required: true

  defp branch_sync(%{sync: %{other_branch: _}} = assigns) do
    ~H"""
    <span
      id="branch-sync"
      class="text-warning"
      title={"Not compared with #{@branch}: the clone has another branch checked out."}
    >
      <span class="font-mono">{@sync.other_branch}</span> checked out
    </span>
    """
  end

  defp branch_sync(%{sync: %{behind: 0, ahead: 0}} = assigns) do
    ~H"""
    <span id="branch-sync" class="inline-flex items-center gap-1 text-ink-3">
      <.icon name="hero-check-mini" class="size-4" /> Up to date
    </span>
    """
  end

  defp branch_sync(assigns) do
    ~H"""
    <span id="branch-sync" class="inline-flex items-center gap-1.5">
      <span :if={@sync.behind > 0} class="font-medium text-warning">
        {@sync.behind} {if @sync.behind == 1, do: "commit", else: "commits"} behind
        <span class="font-mono">origin/{@branch}</span>
      </span>
      <span :if={@sync.behind > 0 and @sync.ahead > 0} class="text-ink-3">·</span>
      <span :if={@sync.ahead > 0} class="text-ink-2">
        {@sync.ahead} ahead<span :if={@sync.behind == 0}> of <span class="font-mono">origin/{@branch}</span></span>
      </span>
    </span>
    """
  end

  defp provisioned_source(:limits), do: "Its limits"
  defp provisioned_source(:host_requirements), do: "hostRequirements"
  defp provisioned_source(:observed), do: "15-minute average"
  defp provisioned_source(_), do: "Not measured yet"
end
