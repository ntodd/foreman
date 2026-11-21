# Developing Foreman

Tool versions are in `mise.toml` (Erlang 29, Elixir 1.20, Node 22).

```sh
mise install

# Control plane (SQLite by default; FOREMAN_DB=postgres for Postgres)
cd apps/foreman
mix setup
mix phx.server          # http://localhost:4000, with a dev sign-in

# Agent, against a local control plane
cd apps/foreman_agent
FOREMAN_URL=http://localhost:4000 FOREMAN_JOIN_TOKEN=fj_... mix run --no-halt
```

An agent run this way enrolls and reports, but can't run environments:
they run in VMs, which need the agent's release, the root helper the
install script sets up, a guest image and KVM. `e2e/vm/run.sh` runs them
for real on a machine you can throw away; see
[e2e/README.md](../e2e/README.md#environment-vms-for-real).

Each app has `mix precommit`, which formats and runs credo and the tests.
The control plane's runs sobelow as well.

## Tests

| Command | What it covers |
|---|---|
| `cd apps/foreman_protocol && mix test` | Message contracts, signatures, redaction |
| `cd apps/foreman_agent && mix test` | Agent logic with fakes for Docker, the CLIs and VMs (a guest agent in the test node, behind a stand-in for vsock) |
| `cd apps/foreman_agent && mix test --only docker` | The environment code a guest agent runs, against real Docker: two copies side by side, secrets, restart affected, rebuild, pull and rebuild and destroy |
| `cd apps/foreman && mix test` | Control plane (run with `FOREMAN_DB=postgres` too) |
| `devcontainer features test ... features` | The feature in a real devcontainer |
| `e2e/` | Full runs: the UI's pages, an emulated Linux box, the guest image under Cloud Hypervisor, environment VMs for real on a throwaway machine, the VM helper with stand-ins, and a real Flatcar box made by the Linux launcher; see [e2e/README.md](../e2e/README.md) |

The README screenshots come from `e2e/demo.exs`, a control plane full of
made-up data, and `e2e/screenshots.mjs`; see
[e2e/README.md](../e2e/README.md#readme-screenshots).
