defmodule ForemanWeb.SetupHTML do
  use ForemanWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <div class="rounded-2xl border border-line bg-raised p-8 shadow-raised">
        <div class="mb-6">
          <p class="text-xs font-medium uppercase tracking-wide text-accent-ink">First run</p>
          <h1 class="mt-1 text-xl font-semibold tracking-tight text-ink">
            Connect Foreman to GitHub
          </h1>
          <p class="mt-1.5 text-sm text-ink-2">
            Foreman signs people in, lists repos and hands each environment its own GitHub token through a GitHub App. Creating it takes one click.
          </p>
        </div>

        <%= if @verified do %>
          <.form for={%{}} action={~p"/setup/github"} method="get" class="space-y-4">
            <.input name="name" value="Foreman" label="App name" />
            <.input
              name="org"
              value=""
              label="Organization (optional)"
              placeholder="Leave empty to create it on your own account"
            />
            <p class="text-xs text-ink-3">
              GitHub will send people back to <span class="font-mono">{@base_url}</span>. It only has to be reachable from your browser, so a tailnet address works.
            </p>
            <.button type="submit" variant="primary" class="w-full justify-center">Continue</.button>
          </.form>
        <% else %>
          <.form for={%{}} action={~p"/setup"} class="space-y-4">
            <.input name="token" value="" label="Setup token" autocomplete="off" required />
            <p class="text-xs text-ink-3">
              It's printed in the control plane's log when it starts without a GitHub App.
            </p>
            <.button type="submit" variant="primary" class="w-full justify-center">Verify</.button>
          </.form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  def github(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <div class="rounded-2xl border border-line bg-raised p-8 shadow-raised">
        <h1 class="text-xl font-semibold tracking-tight text-ink">Create the GitHub App</h1>
        <p class="mt-1.5 text-sm text-ink-2">
          GitHub will show you the app's settings. Its permissions: contents, pull requests and issues (write), workflows (write), members (read). Click "Create GitHub App" there, and you'll come back here.
        </p>
        <form action={@action} method="post" class="mt-6">
          <input type="hidden" name="manifest" value={@manifest} />
          <.button
            type="submit"
            variant="primary"
            class="w-full justify-center"
            icon="hero-arrow-top-right-on-square"
          >
            Continue on GitHub
          </.button>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
