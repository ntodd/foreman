# What the devcontainer CLI generates

`project/devcontainer` is a compose-based devcontainer with two local
features. `generated/` is what the devcontainer CLI wrote when it brought
that project up (0.89.0 and 0.90.0 write the same bytes):

    devcontainer up --workspace-folder <project> --id-label oracle=1 \
      --skip-post-attach --gpu-availability none --no-lockfile

- `Dockerfile-with-features`, `devcontainer-features.builtin.env` and each
  feature's `devcontainer-features.env` and
  `devcontainer-features-install.sh` are from its build folder
  (`$TMPDIR/devcontainercli/container-features/<version>-<time>/`).
- `build.yml` and `start.yml` are its two compose overrides
  (`$TMPDIR/devcontainercli/docker-compose/`), with the build folder's
  path replaced by `{{BUILD}}` in the first.

`ForemanAgent.Devcontainer`'s tests generate the same files from the same
project and compare them byte for byte, which is what lets an image built
by the agent reuse the layers the CLI built, and the other way round.
`../collation.json` is how JavaScript's `localeCompare` orders the strings
feature ids are made of, which decides the order features install in.
