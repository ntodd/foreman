defmodule ForemanAgent.Devcontainer.Features.Build do
  @moduledoc """
  What installs features into an image: the stages that go on the end of
  a Dockerfile, and the files beside each feature in the build folder (its
  options as variables, and a wrapper that runs its `install.sh` with
  them).

  The build folder is a BuildKit build context
  (`dev_containers_feature_content_source`); each feature is mounted from
  it for the one `RUN` that installs it. All of it is written the way the
  devcontainer CLI writes it, instruction for instruction, so an image
  built by one reuses the layers the other built.
  """

  alias ForemanAgent.Devcontainer.{Dockerfile, Metadata}
  alias ForemanAgent.SafeFS

  @container_dir "/tmp/dev-container-features"
  @builtin_env "devcontainer-features.builtin.env"
  @target "dev_containers_target_stage"

  @type t :: %{
          prefix: String.t(),
          content: String.t(),
          target: String.t(),
          args: [{String.t(), String.t()}],
          contexts: [{String.t(), Path.t()}]
        }

  @doc """
  Writes the files the build reads: the users features install for, and
  for each feature its variables and install wrapper.
  """
  @spec write_files([map()], Path.t(), String.t(), String.t()) :: :ok
  def write_files(sets, dst, container_user, remote_user) do
    File.mkdir_p!(dst)

    write!(
      Path.join(dst, @builtin_env),
      "_CONTAINER_USER=#{container_user}\n_REMOTE_USER=#{remote_user}\n"
    )

    for set <- sets do
      variables = variables(set)
      write!(Path.join(set.cache_path, "devcontainer-features.env"), Enum.join(variables, "\n"))

      write!(
        Path.join(set.cache_path, "devcontainer-features-install.sh"),
        wrapper(set, variables)
      )
    end

    :ok
  end

  # A feature's folder is the feature's own files, links and all. A new
  # file renamed into place replaces a link that's where one of these
  # goes; writing to the path would write through it.
  defp write!(path, content) do
    case SafeFS.write_atomic(path, content, 0o644) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write to file", path: path
    end
  end

  @doc """
  A feature's options as `NAME="value"` lines: the defaults it declares,
  then what the config set. A plain value in the config (`"1.22"`) is the
  `version` option, for a feature that has one.
  """
  @spec variables(map()) :: [String.t()]
  def variables(set) do
    options = if is_map(set.metadata["options"]), do: set.metadata["options"], else: %{}
    names = ordered_keys(options, set.order["options"])

    defaults =
      for name <- names,
          is_map(options[name]),
          Map.has_key?(options[name], "default"),
          do: {name, options[name]["default"]}

    given =
      cond do
        is_map(set.value) ->
          set.value |> Map.keys() |> Enum.sort() |> Enum.map(&{&1, set.value[&1]})

        truthy?(options["version"]) ->
          [{"version", set.value}]

        true ->
          []
      end

    given
    |> Enum.reduce(defaults, fn {name, value}, acc ->
      List.keystore(acc, name, 0, {name, value})
    end)
    |> Enum.map(fn {name, value} -> ~s(#{safe_id(name)}="#{to_text(value)}") end)
  end

  defp truthy?(value), do: value not in [nil, false, "", 0]

  @doc "A name as a shell variable: letters, digits and `_`, not starting with a digit."
  @spec safe_id(String.t()) :: String.t()
  def safe_id(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> String.replace(~r/^[\d_]+/, "_")
    |> String.upcase()
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(nil), do: "null"

  defp to_text(value) when is_float(value) and trunc(value) == value,
    do: Integer.to_string(trunc(value))

  defp to_text(value) when is_map(value) or is_list(value), do: JSON.encode!(value)
  defp to_text(value), do: to_string(value)

  # An object's keys in the order its file had them; ones the order
  # doesn't know (it came from elsewhere) go last, sorted.
  defp ordered_keys(map, order) do
    known = for key <- order || [], Map.has_key?(map, key), do: key
    known ++ Enum.sort(Map.keys(map) -- known)
  end

  @doc "The script that installs a feature: it says what's being installed, then runs `install.sh`."
  @spec wrapper(map(), [String.t()]) :: String.t()
  def wrapper(set, variables) do
    metadata = set.metadata
    id = quoted(set.source[:user_feature_id_without_version] || "Unknown")
    name = quoted(metadata["name"] || "Unknown")
    documentation = quoted(metadata["documentationURL"] || "")
    options = quoted(Enum.map_join(variables, "\n", &("    " <> &1)))

    warning = deprecated_warning(set) <> renamed_warning(set)

    troubleshooting =
      if documentation == "",
        do: "",
        else:
          " Look at the documentation at #{documentation} for help troubleshooting this error."

    """
    #!/bin/sh
    set -e

    on_exit () {
    \t[ $? -eq 0 ] && exit
    \techo 'ERROR: Feature "#{name}" (#{id}) failed to install!#{troubleshooting}'
    }

    trap on_exit EXIT

    echo ===========================================================================
    #{if warning == "", do: "", else: "echo '#{warning}'"}
    echo 'Feature       : #{name}'
    echo 'Description   : #{quoted(metadata["description"] || "")}'
    echo 'Id            : #{id}'
    echo 'Version       : #{quoted(metadata["version"] || "")}'
    echo 'Documentation : #{documentation}'
    echo 'Options       :'
    echo '#{options}'
    echo ===========================================================================

    set -a
    . ../devcontainer-features.builtin.env
    . ./devcontainer-features.env
    set +a

    chmod +x ./install.sh
    ./install.sh
    """
  end

  defp deprecated_warning(%{id: id, metadata: %{"deprecated" => true}}),
    do:
      ~s|(!) WARNING: Using the deprecated Feature "#{quoted(id)}". This Feature will no longer receive any further updates/support.\n|

  defp deprecated_warning(_set), do: ""

  defp renamed_warning(%{id: id, metadata: %{"legacyIds" => [_ | _], "currentId" => current}})
       when is_binary(current) and id != current,
       do:
         ~s|(!) WARNING: This feature has been renamed. Please update the reference in devcontainer.json to "#{quoted(current)}".|

  defp renamed_warning(_set), do: ""

  # For text inside single quotes in a shell script.
  defp quoted(text) when is_binary(text), do: String.replace(text, "'", "'\\''")
  defp quoted(other), do: quoted(to_text(other))

  @doc """
  The stages that install `sets` on top of the stage or image
  `base_name`. Options: `:dst` (the build folder), `:base_name`,
  `:image_user` (who the image runs as, restored at the end),
  `:container_user` and `:remote_user` (whose homes features are told),
  `:metadata` (the image's metadata entries), `:container_env` and
  `:container_env_order` (the config's own), `:syntax` (the Dockerfile's
  syntax directive, kept).
  """
  @spec dockerfile([map()], keyword()) :: t()
  def dockerfile(sets, opts) do
    builtin = Path.join(@container_dir, @builtin_env)

    homes =
      "RUN \\\n" <>
        ~s|echo "_CONTAINER_USER_HOME=$(#{passwd_command(opts[:container_user])} \| cut -d: -f6)" >> #{builtin} && \\\n| <>
        ~s|echo "_REMOTE_USER_HOME=$(#{passwd_command(opts[:remote_user])} \| cut -d: -f6)" >> #{builtin}\n\n|

    layers = Enum.map_join(sets, "", &layer/1)
    config_env = env(opts[:container_env], opts[:container_env_order], true)

    content = """


    #{""}

    ARG _DEV_CONTAINERS_BASE_IMAGE=scratch

    FROM $_DEV_CONTAINERS_BASE_IMAGE AS dev_containers_feature_content_normalize
    USER root
    COPY --from=dev_containers_feature_content_source #{@builtin_env} /tmp/build-features/
    RUN chmod -R 0755 /tmp/build-features/

    FROM $_DEV_CONTAINERS_BASE_IMAGE AS #{@target}

    USER root

    RUN mkdir -p #{@container_dir}
    COPY --from=dev_containers_feature_content_normalize /tmp/build-features/ #{@container_dir}

    #{homes <> layers}

    #{""}

    ARG _DEV_CONTAINERS_IMAGE_USER=root
    USER $_DEV_CONTAINERS_IMAGE_USER

    #{Metadata.label(opts[:metadata])}

    #{config_env}
    """

    %{
      prefix: prefix(Dockerfile.feature_syntax(opts[:syntax])),
      content: content,
      target: @target,
      args: [
        {"_DEV_CONTAINERS_BASE_IMAGE", opts[:base_name]},
        {"_DEV_CONTAINERS_IMAGE_USER", opts[:image_user]},
        {"_DEV_CONTAINERS_FEATURE_CONTENT_SOURCE", "dev_container_feature_content_temp"}
      ],
      contexts: [{"dev_containers_feature_content_source", opts[:dst]}]
    }
  end

  @doc "A stage that only puts the metadata label on `base_name`, for an image with no features."
  @spec label_only(String.t(), [map()], String.t() | nil) :: t()
  def label_only(base_name, metadata, syntax) do
    %{
      prefix: prefix(syntax),
      content: "\nFROM $_DEV_CONTAINERS_BASE_IMAGE AS #{@target}\n#{Metadata.label(metadata)}\n",
      target: @target,
      args: [{"_DEV_CONTAINERS_BASE_IMAGE", base_name}],
      contexts: []
    }
  end

  defp prefix(syntax),
    do:
      if(syntax, do: "# syntax=#{syntax}", else: "") <>
        "\nARG _DEV_CONTAINERS_BASE_IMAGE=scratch\n"

  # One feature: its environment, which the features after it see, then
  # its install with its folder mounted from the build context.
  defp layer(set) do
    id = set.consecutive_id
    dest = Path.join(@container_dir, id)

    env(set.metadata["containerEnv"], set.order["containerEnv"], false) <>
      """

      RUN --mount=type=bind,from=dev_containers_feature_content_source,source=#{id},target=/tmp/build-features-src/#{id} \\
          cp -ar /tmp/build-features-src/#{id} #{@container_dir} \\
       && chmod -R 0755 #{dest} \\
       && cd #{dest} \\
       && chmod +x ./devcontainer-features-install.sh \\
       && ./devcontainer-features-install.sh \\
       && rm -rf #{dest}

      """
  end

  # ENV instructions. A feature's can refer to variables (`${PATH}`); the
  # config's are literal, so their dollars are escaped too.
  defp env(env, order, escape_dollar?) when is_map(env) do
    pattern = if escape_dollar?, do: ~r/(?=["\\$])/, else: ~r/(?=["\\])/

    env
    |> ordered_keys(order)
    |> Enum.map_join("\n", fn key ->
      ~s(ENV #{key}="#{String.replace(to_text(env[key]), pattern, "\\")}")
    end)
  end

  defp env(_env, _order, _escape_dollar?), do: ""

  @doc """
  A shell command that prints a user's passwd entry, by name or id, from
  `getent` or `/etc/passwd`.
  """
  @spec passwd_command(String.t()) :: String.t()
  def passwd_command(user) do
    for_shell = String.replace(user, ~r/['\\]/, "\\\\\\0")

    for_regex =
      user |> String.replace(~r/[.*+?^${}()|\[\]\\]/, "\\\\\\0") |> String.replace("'", "\\'")

    # The leading space keeps `$( (` from reading as arithmetic.
    " (command -v getent >/dev/null 2>&1 && getent passwd '#{for_shell}' || " <>
      "grep -E '^#{for_regex}|^[^:]*:[^:]*:#{for_regex}:' /etc/passwd || true)"
  end
end
