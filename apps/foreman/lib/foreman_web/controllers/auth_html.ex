defmodule ForemanWeb.AuthHTML do
  use ForemanWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <div class="rounded-2xl border border-line bg-raised p-8 shadow-raised">
        <div class="mb-6 flex flex-col items-center text-center">
          <Layouts.mark size="lg" />
          <h1 class="mt-4 text-xl font-semibold tracking-tight text-ink">Sign in to Foreman</h1>
          <p class="mt-1.5 text-sm text-ink-2">
            Dev environments on your own machines, one click away.
          </p>
        </div>

        <.button
          href={~p"/auth/github"}
          variant="primary"
          class="w-full justify-center"
          icon="hero-arrow-right-end-on-rectangle"
        >
          Continue with GitHub
        </.button>

        <p :if={@dev_sign_in} class="mt-5 text-center text-xs text-ink-3">
          Development:
          <.link href={~p"/dev/sign-in/dev"} class="font-medium text-accent-ink underline">sign in as "dev"</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end
end
