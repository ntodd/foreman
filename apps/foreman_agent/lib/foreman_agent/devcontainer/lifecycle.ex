defmodule ForemanAgent.Devcontainer.Lifecycle do
  @moduledoc """
  What happens in a devcontainer once it runs: its environment is made
  the same for login shells (`/etc/environment`, `/etc/profile`), the
  remote user's shell environment is read, and the lifecycle commands run
  as that user in the workspace: `onCreateCommand`, `updateContentCommand`
  and `postCreateCommand` once for a container, dotfiles after them,
  `postStartCommand` each time it starts, `postAttachCommand` unless
  skipped. A marker file per hook in the user's `~/.devcontainer` holds
  when the container was created (or started), which is how a hook knows
  it has run.

  Commands run through `docker exec`, without a terminal.
  """

  alias ForemanAgent.Devcontainer.Features.Build
  alias ForemanAgent.Devcontainer.Substitute
  alias ForemanAgent.Runner.Logged

  @system_folder "/var/devcontainer"
  @probe_timeout 10_000
  @quiet_timeout :timer.minutes(2)

  @create_hooks ~w(onCreateCommand updateContentCommand postCreateCommand)

  @dotfiles_installers ~w(install.sh install bootstrap.sh bootstrap script/bootstrap setup.sh setup script/setup)

  @doc """
  Sets a running container up. `params`:

    * `:container` - the container, as `docker inspect` has it
    * `:merged` - the merged config (`Metadata.merge/2`)
    * `:origins` - each hook's commands (`Metadata.lifecycle_origins/1`)
    * `:remote_workspace_folder` - where commands run
    * `:dotfiles` - `%{repository:, install_command:, target_path:}` or nil
    * `:skip_post_attach` - true unless given
    * `:env` - the environment `docker` runs with
    * `:deadline` - when to give up, in monotonic milliseconds
    * `:timed_out` - what to say then

  Returns the user the commands ran as and the environment they got.
  """
  @spec run(map(), map()) ::
          {:ok, %{remote_user: String.t(), remote_env: map()}} | {:error, String.t()}
  def run(params, ctx) do
    container = params.container
    config = container["Config"] || %{}
    exec_user = params.merged["remoteUser"] || non_empty(config["User"]) || "root"

    state = %{
      ctx: ctx,
      id: container["Id"],
      docker_env: params.env,
      deadline: params.deadline,
      timed_out: params[:timed_out] || "the devcontainer wasn't ready in time",
      exec_user: exec_user,
      user: user_name(exec_user),
      env: env_map(config["Env"]),
      cwd: params.remote_workspace_folder
    }

    with {:ok, passwd} <- passwd(state),
         state = Map.put(state, :shell, env(state, "SHELL") || passwd[:shell] || "/bin/sh"),
         {:ok, home} <- home(state, passwd),
         state = Map.merge(state, %{home: home, data_folder: Path.expand(".devcontainer", home)}),
         :ok <- patch_etc(state),
         {:ok, remote_env} <- remote_env(state, params.merged),
         state = Map.put(state, :remote_env, remote_env),
         :ok <- hooks(state, params, container) do
      {:ok, %{remote_user: state.user, remote_env: remote_env}}
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  # `user[:group]`, as a container's config or a remoteUser has it.
  defp user_name(exec_user) do
    case exec_user |> String.split(":", parts: 2) |> hd() do
      "0" -> "root"
      name -> name
    end
  end

  # In the container's own order, which /etc/environment keeps.
  defp env_map(list) do
    for pair <- list || [],
        [name, value] <- [String.split(pair, "=", parts: 2)],
        do: {name, value}
  end

  # -- the user ------------------------------------------------------------

  defp passwd(state) do
    # The first command in the container: if this user can't run one
    # (the image doesn't have it, say), nothing after would run either.
    case quiet(state, state.exec_user, sh(Build.passwd_command(state.user))) do
      {:ok, %{status: 0, output: output}} ->
        entry = passwd_entry(output)

        if is_nil(entry),
          do:
            state.ctx.log.(
              "info",
              "User #{state.user} isn't in the container's passwd database\n"
            )

        {:ok, entry || %{}}

      {:ok, %{output: output}} ->
        {:error, unusable(state, output)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp passwd_entry(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(String.trim_trailing(line, "\r"), ":") do
        [name, _, uid, gid, _, home, shell | _] ->
          %{name: name, uid: uid, gid: gid, home: home, shell: shell}

        _ ->
          nil
      end
    end)
  end

  defp unusable(state, output),
    do: "couldn't run commands in the devcontainer as #{state.user}: #{Logged.last_lines(output)}"

  # HOME from the container's environment when it's the user's own or one
  # they can use; else the passwd entry's.
  defp home(state, passwd) do
    case env(state, "HOME") do
      nil ->
        {:ok, passwd[:home] || "/root"}

      home ->
        cond do
          home == passwd[:home] or passwd[:uid] == "0" ->
            {:ok, home}

          match?(
            {:ok, %{status: 0}},
            quiet(state, state.exec_user, sh("[ ! -e '#{home}' ] || [ -w '#{home}' ]"))
          ) ->
            {:ok, home}

          true ->
            {:ok, passwd[:home] || "/root"}
        end
    end
  end

  defp env(state, name) do
    case List.keyfind(state.env, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # -- system files --------------------------------------------------------

  # A login shell starts from /etc/environment and /etc/profile, not from
  # the container's own environment; these make it see the same.
  defp patch_etc(state) do
    variables = Enum.map_join(state.env, "", fn {name, value} -> ~s(\n#{name}="#{value}") end)

    with :ok <-
           once(
             state,
             ".patchEtcEnvironmentMarker",
             "cat >> /etc/environment <<'etcEnvironmentEOF'\n#{variables}\netcEnvironmentEOF\n"
           ) do
      once(
        state,
        ".patchEtcProfileMarker",
        ~S"sed -i -E 's/((^|\s)PATH=)([^\$]*)$/\1${PATH:-\3}/g' /etc/profile || true"
      )
    end
  end

  defp once(state, marker, script) do
    path = Path.join(@system_folder, marker)

    with {:ok, %{status: status}} when status != 0 <-
           quiet(state, state.exec_user, sh("test -f '#{path}'")),
         {:ok, %{status: 0}} <- quiet(state, "root", sh(create_file(path))),
         {:ok, _} <- quiet(state, "root", sh(script)) do
      :ok
    else
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  # Succeeds only for whoever creates the file.
  defp create_file(path) do
    "test ! -f '#{path}' && set -o noclobber && mkdir -p '#{Path.dirname(path)}' && { > '#{path}' ; } 2> /dev/null"
  end

  # -- the remote environment ----------------------------------------------

  defp remote_env(state, merged) do
    probe = merged["userEnvProbe"] || "loginInteractiveShell"
    state.ctx.log.("info", "Reading #{state.user}'s shell environment (#{probe})\n")

    with {:ok, configured} <-
           Substitute.container_env(merged["remoteEnv"] || %{}, Map.new(state.env)) do
      env =
        state
        |> probe(probe)
        |> Map.merge(
          for({name, value} <- configured, is_binary(value), into: %{}, do: {name, value})
        )
        |> Map.drop(for {name, nil} <- configured, do: name)

      {:ok, env}
    end
  end

  defp probe(_state, "none"), do: %{}

  defp probe(state, probe) do
    case probe_with(state, probe, "cat /proc/self/environ", "\0") do
      :unreadable -> with :unreadable <- probe_with(state, probe, "printenv", "\n"), do: %{}
      env -> env
    end
  end

  defp probe_with(state, probe, command, separator) do
    mark = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    argv =
      [state.shell | probe_flags(state.shell, probe)] ++
        ["echo -n #{mark}; #{command}; echo -n #{mark}"]

    # Raw: the environment is separated by NULs, which output made into
    # text for the log doesn't keep. Without them it reads as one
    # variable, and every command after runs without the shell's
    # environment: no secrets from /run/foreman, no PATH a profile set.
    case quiet(state, state.exec_user, argv, timeout: @probe_timeout, keep: 1_048_576, raw: true) do
      {:ok, %{status: 0, output: output}} ->
        probed(output, mark, separator)

      {:ok, _} ->
        state.ctx.log.("info", "Couldn't read the shell environment; carrying on without it\n")
        %{}

      {:error, _} ->
        state.ctx.log.(
          "info",
          "Reading the shell environment took over 10 seconds. A shell's startup scripts shouldn't wait for input; carrying on without it\n"
        )

        %{}
    end
  end

  # How to have a shell run one command as the kind of shell `probe` names.
  defp probe_flags(shell, probe) do
    if Regex.match?(~r/^pwsh(-preview)?$/, Path.basename(shell)) do
      if probe in ["loginInteractiveShell", "loginShell"],
        do: ["-Login", "-Command"],
        else: ["-Command"]
    else
      [
        Map.get(
          %{
            "loginInteractiveShell" => "-lic",
            "loginShell" => "-lc",
            "interactiveShell" => "-ic"
          },
          probe,
          "-c"
        )
      ]
    end
  end

  # The environment between the marks, past whatever the shell's startup
  # printed around them.
  defp probed(output, mark, separator) do
    case Regex.run(~r/#{mark}(.*)#{mark}/s, output) do
      [_, inner] when inner != "" ->
        # Made text only now, a variable at a time: these go into command
        # lines and into what the control plane is told.
        for pair <- String.split(inner, separator),
            [name, value] <- [String.split(pair, "=", parts: 2)],
            name != "PWD",
            into: %{},
            do: {ForemanAgent.Text.scrub(name), ForemanAgent.Text.scrub(value)}

      _ ->
        :unreadable
    end
  end

  # -- hooks ---------------------------------------------------------------

  defp hooks(state, params, container) do
    created = container["Created"]
    started = get_in(container, ["State", "StartedAt"])

    with :ok <- each(@create_hooks, &hook(state, params.origins, &1, created)),
         :ok <- dotfiles(state, params[:dotfiles]),
         :ok <- hook(state, params.origins, "postStartCommand", started) do
      if Map.get(params, :skip_post_attach, true),
        do: :ok,
        else: commands(state, params.origins, "postAttachCommand")
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Runs a hook's commands unless its marker already holds `stamp`.
  defp hook(_state, _origins, _name, stamp) when not is_binary(stamp), do: :ok

  defp hook(state, origins, name, stamp) do
    dir = state.data_folder
    marker = Path.join(dir, ".#{name}Marker")

    # Ends 0 when the marker is new or held another stamp (and holds this
    # one now), 20 when it already held this one, 21 when it couldn't be
    # kept. Not 1: that's also what docker gives when it can't run the
    # script at all (the container stopped under it), and a hook mustn't
    # be skipped for that. The stamp is written beside the marker and
    # moved into place, since a marker left empty by a write that failed
    # reads as "already ran".
    script =
      "mkdir -p '#{dir}' && [ ! -d '#{marker}' ] || exit 21; CONTENT=\"$(cat '#{marker}' 2>/dev/null || echo ENOENT)\"; " <>
        "[ \"${CONTENT:-#{stamp}}\" != '#{stamp}' ] || exit 20; echo '#{stamp}' > '#{marker}.tmp' && mv -f '#{marker}.tmp' '#{marker}' || exit 21"

    case quiet(state, state.exec_user, sh(script)) do
      {:ok, %{status: 0}} ->
        commands(state, origins, name)

      {:ok, %{status: 20}} ->
        :ok

      # Without a marker there's no telling whether the hook has run.
      # Running it on every start, or never, are both worse than saying so.
      {:ok, %{output: output}} ->
        if Enum.any?(origins[name] || [], fn {_origin, command} -> command?(command) end),
          do:
            {:error,
             "couldn't record that the #{name} ran (in #{dir}, as #{state.user}): #{Logged.last_lines(output)}"},
          else: :ok

      {:error, message} ->
        {:error, message}
    end
  end

  defp commands(state, origins, hook) do
    each(origins[hook] || [], fn {origin, command} ->
      origin = if origin == "devcontainer.json", do: origin, else: "Feature '#{origin}'"

      if command?(command) do
        state.ctx.log.("info", "Running the #{hook} from #{origin}...\n")
        command(state, command, hook, origin)
      else
        :ok
      end
    end)
  end

  defp command?(command) when is_binary(command), do: String.trim(command) != ""
  defp command?(command) when is_list(command), do: command != []
  defp command?(command) when is_map(command), do: map_size(command) > 0
  defp command?(_command), do: false

  # An object's commands run at the same time. Each one's output is held
  # until it's done, so they don't run together in the log.
  defp command(state, %{} = named, hook, origin) do
    named
    |> Enum.sort()
    |> Enum.map(fn {name, command} ->
      Task.async(fn ->
        {status, output} = collect(state, argv(command))
        state.ctx.log.("info", "Running #{name} of #{hook} from #{origin}...\n#{output}\n")
        failure(status, "#{name} of #{hook} from #{origin}")
      end)
    end)
    |> Task.await_many(:infinity)
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp command(state, command, hook, origin) do
    case user(state, argv(command), & &1) do
      {:ok, %{status: status}} -> failure(status, "#{hook} from #{origin}")
      {:error, message} -> {:error, message}
    end
  end

  defp collect(state, argv) do
    case user(state, argv, fn _ -> nil end) do
      {:ok, %{status: status, output: output}} -> {status, Logged.shown(output)}
      {:error, message} -> {{:error, message}, ""}
    end
  end

  defp failure(0, _what), do: :ok
  defp failure({:error, message}, _what), do: {:error, message}
  defp failure(status, what), do: {:error, "#{what} failed with exit code #{status}"}

  defp argv(command) when is_binary(command), do: sh(command)
  defp argv(command) when is_list(command), do: Enum.map(command, &to_string/1)

  defp sh(script), do: ["/bin/sh", "-c", script]

  # -- dotfiles ------------------------------------------------------------

  defp dotfiles(_state, nil), do: :ok
  defp dotfiles(_state, %{repository: nil}), do: :ok

  defp dotfiles(state, dotfiles) do
    state.ctx.log.("info", "Installing dotfiles\n")

    # Whatever goes wrong with someone's dotfiles, the environment is still theirs to use.
    case user(state, sh(dotfiles_script(state, dotfiles)), & &1, cwd: nil, env: %{}) do
      {:error, message} -> state.ctx.log.("info", "Dotfiles: #{message}\n")
      _ -> :ok
    end

    :ok
  end

  defp dotfiles_script(state, dotfiles) do
    repository = dotfiles.repository

    repository =
      if String.contains?(repository, ":") or Regex.match?(~r/^\.{0,2}\//, repository),
        do: repository,
        else: "https://github.com/#{repository}.git"

    target = dotfiles[:target_path] || "~/dotfiles"
    marker = create_file(Path.join(state.data_folder, ".dotfilesMarker"))

    env =
      state.remote_env
      |> Enum.reject(fn {name, _} ->
        String.starts_with?(name, "BASH_FUNC_") and String.ends_with?(name, "%%")
      end)
      |> Enum.sort()
      |> Enum.map_join("", fn {name, value} -> "#{name}=#{quote_value(value)} " end)

    clone = """
    #{marker} || (echo dotfiles marker found && exit 1) || exit 0
    command -v git >/dev/null 2>&1 || (echo git not found && exit 1) || exit 0
    [ -e #{target} ] || #{env}git clone --depth 1 #{repository} #{target} || exit $?
    """

    case dotfiles[:install_command] do
      nil ->
        """
        # Clone & install dotfiles
        #{clone}echo Setting current directory to #{target}
        cd #{target}
        for f in #{Enum.join(@dotfiles_installers, " ")}
        do
        \tif [ -e $f ]
        \tthen
        \t\tinstallCommand=$f
        \t\tbreak
        \tfi
        done
        if [ -z "$installCommand" ]
        then
        \tdotfiles=$(ls -d #{target}/.* 2>/dev/null | grep -v -E '/(.|..|.git)$')
        \tif [ ! -z "$dotfiles" ]
        \tthen
        \t\techo Linking dotfiles: $dotfiles
        \t\tln -sf $dotfiles ~ 2>/dev/null
        \telse
        \t\techo No dotfiles found.
        \tfi
        else
        \tif [ ! -x "$installCommand" ]
        \tthen
        \t   echo Setting '#{target}'/"$installCommand" as executable
        \t   chmod +x "$installCommand"
        \tfi

        \techo Executing command '#{target}'/"$installCommand"...\\n
        \t#{env}./"$installCommand"
        fi
        """

      install ->
        """
        # Clone & install dotfiles via '#{install}'
        #{clone}echo Setting current directory to '#{target}'
        cd #{target}

        if [ -f "./#{install}" ]
        then
        \tif [ ! -x "./#{install}" ]
        \tthen
        \t\techo Setting './#{install}' as executable
        \t\tchmod +x "./#{install}"
        \tfi
        \techo Executing command './#{install}'..\\n
        \t#{env}"./#{install}"
        elif [ -f "#{install}" ]
        then
        \tif [ ! -x "#{install}" ]
        \tthen
        \t\techo Setting '#{install}' as executable
        \t\tchmod +x "#{install}"
        \tfi
        \techo Executing command '#{install}'...\\n
        \t#{env}"#{install}"
        else
        \techo Could not locate '#{install}'...\\n
        \texit 126
        fi
        """
    end
  end

  defp quote_value(value), do: "'" <> Regex.replace(~r/'+/, value || "", "'\"\\0\"'") <> "'"

  # -- docker exec ---------------------------------------------------------

  # A command of the user's: in the workspace, with the remote environment,
  # its output in the log (through `mapper`).
  defp user(state, argv, mapper, opts \\ []) do
    env = Keyword.get(opts, :env, state.remote_env)
    cwd = Keyword.get(opts, :cwd, state.cwd || state.home)

    exec(state, state.exec_user, argv, mapper,
      env: env,
      cwd: cwd,
      label: "the command",
      timed_out: state.timed_out
    )
  end

  # Bookkeeping, which nobody needs to read.
  defp quiet(state, user, argv, opts \\ []) do
    exec(
      state,
      user,
      argv,
      fn _ -> nil end,
      [timeout: @quiet_timeout, label: "docker exec"] ++ opts
    )
  end

  defp exec(state, user, argv, mapper, opts) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    timeout = min(Keyword.get(opts, :timeout, remaining), remaining)

    args =
      ["exec", "-i", "-u", user] ++
        Enum.flat_map(Enum.sort(opts[:env] || %{}), fn {name, value} ->
          ["-e", "#{name}=#{value}"]
        end) ++
        if(opts[:cwd], do: ["-w", opts[:cwd]], else: []) ++
        [state.id | argv]

    if timeout <= 0 do
      {:error, state.timed_out}
    else
      Logged.run(
        state.ctx,
        state.ctx.config.docker,
        args,
        [
          env: state.docker_env,
          timeout: timeout,
          keep: Keyword.get(opts, :keep, 65_536),
          raw: Keyword.get(opts, :raw, false),
          label: opts[:label],
          timed_out: opts[:timed_out]
        ],
        mapper
      )
    end
  end
end
