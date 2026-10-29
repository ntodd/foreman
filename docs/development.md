# Developing Foreman

Tool versions are in `mise.toml` (Erlang 29, Elixir 1.20, Node 22).

```sh
mise install

# Control plane (SQLite by default; FOREMAN_DB=postgres for Postgres)
cd apps/foreman
mix setup
mix phx.server          # http://localhost:4000, with a dev sign-in

# Agent, against a local control plane and Docker Desktop
cd apps/foreman_agent
FOREMAN_URL=http://localhost:4000 FOREMAN_JOIN_TOKEN=fj_... mix run --no-halt
```

Each app has `mix precommit`, which formats and runs credo and the tests.
The control plane's runs sobelow as well.

## Tests

| Command | What it covers |
|---|---|
| `cd apps/foreman_protocol && mix test` | Message contracts, signatures, redaction |
| `cd apps/foreman_agent && mix test` | Agent logic with fakes for Docker and the CLIs |
| `cd apps/foreman_agent && mix test --only docker` | The agent against real Docker and the devcontainer CLI: two copies side by side, secrets, restart affected, rebuild, pull and rebuild and destroy, plus refusing a tampered compose file and a feature that asks for privileged |
| `cd apps/foreman && mix test` | Control plane (run with `FOREMAN_DB=postgres` too) |
| `devcontainer features test ... features` | The feature in a real devcontainer |
| `e2e/` | Full runs through the UI, on an emulated Linux box, and on a real Flatcar box made by the Mac or Linux launcher; see [e2e/README.md](../e2e/README.md) |

The README screenshots come from `e2e/demo.exs`, a control plane full of
made-up data, and `e2e/screenshots.mjs`; see
[e2e/README.md](../e2e/README.md#readme-screenshots).
