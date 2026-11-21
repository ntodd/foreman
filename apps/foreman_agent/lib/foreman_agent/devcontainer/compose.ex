defmodule ForemanAgent.Devcontainer.Compose do
  @moduledoc """
  The compose files a devcontainer adds to a repo's own, both for its one
  service:

    * a build override, which builds the service's image from a Dockerfile
      with the features on the end
    * a start override, which runs it the way the merged config says: the
      features' entrypoints around the service's own command, the config's
      environment, mounts, capabilities and labels

  Both are written out as the devcontainer CLI writes them. Compose
  interpolates `$` in what it reads, so a literal one is doubled.
  """

  alias ForemanAgent.Devcontainer.Metadata

  @type service_build :: %{
          context: Path.t(),
          dockerfile_path: Path.t(),
          target: String.t() | nil,
          args: map()
        }

  @doc "A project name as compose takes it: lowercase letters, digits, `-` and `_`."
  @spec project_name(String.t()) :: String.t()
  def project_name(name), do: name |> String.downcase() |> String.replace(~r/[^-_a-z0-9]/, "")

  @doc "The `version:` line of a compose file, which files layered on it repeat."
  @spec version_prefix(String.t()) :: String.t()
  def version_prefix(compose_file) do
    case Regex.run(~r/^\s*(version:.*)$/m, compose_file) do
      [_, version] -> version <> "\n\n"
      nil -> ""
    end
  end

  @doc """
  How a service is built, from compose's resolved config: nil when it only
  names an image.
  """
  @spec service_build(map(), [Path.t()]) :: service_build() | nil
  def service_build(%{"build" => build}, _compose_files) when is_binary(build),
    do: %{context: build, dockerfile_path: Path.join(build, "Dockerfile"), target: nil, args: %{}}

  def service_build(%{"build" => %{} = build}, compose_files) do
    context =
      build["context"] ||
        case compose_files do
          [first | _] -> Path.dirname(first)
          [] -> "."
        end

    %{
      context: context,
      dockerfile_path: Path.expand(build["dockerfile"] || "Dockerfile", context),
      target: build["target"],
      args: build_args(build["args"])
    }
  end

  def service_build(_service, _compose_files), do: nil

  defp build_args(args) when is_map(args),
    do: Map.new(args, fn {k, v} -> {k, if(is_nil(v), do: "", else: to_string(v))} end)

  defp build_args(args) when is_list(args) do
    for arg <- args, is_binary(arg), into: %{} do
      case String.split(arg, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end
    end
  end

  defp build_args(_args), do: %{}

  @doc """
  The entrypoint and command the container ends up running, once the
  features' entrypoints have run: the service's own, else the image's.
  The command is `:keep` when the compose files already give it.
  `overrideCommand` runs neither, so the container just stays up.
  """
  @spec user_commands(map(), map(), boolean() | nil) :: {[String.t()], [String.t()] | :keep}
  def user_commands(_service, _image_config, true), do: {[], []}

  def user_commands(service, image_config, _override_command) do
    entrypoint = words(service["entrypoint"])
    command = words(service["command"])

    {entrypoint || escaped(image_config["Entrypoint"]),
     cond do
       command -> :keep
       # Compose ignores an image's command when the service has an entrypoint.
       entrypoint -> []
       true -> escaped(image_config["Cmd"])
     end}
  end

  defp words(nil), do: nil
  defp words(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp words(string) when is_binary(string), do: OptionParser.split(string)

  defp escaped(nil), do: []
  defp escaped(list), do: Enum.map(list, &String.replace(&1, "$", "$$"))

  @doc """
  The override that builds the service from `:dockerfile`. `:build` is a
  `Features.Build`; `:service_build` is how the service was built before
  (nil for one that names an image, which gets `:image` as its name and
  `:empty_context` to build in).
  """
  @spec build_override(map()) :: String.t()
  def build_override(params) do
    %{build: build, service_build: service_build} = params

    lines =
      [
        if(is_nil(service_build), do: "    image: #{params.image}"),
        "    build:",
        "      dockerfile: #{params.dockerfile}",
        if(service_build && service_build.target, do: "      target: #{build.target}"),
        if(is_nil(service_build) or is_nil(service_build.context),
          do: "      context: #{params.empty_context}"
        ),
        "      args:",
        "        - BUILDKIT_INLINE_CACHE=1",
        for({name, value} <- build.args, do: "        - #{name}=#{value}"),
        if(build.contexts != [], do: "      additional_contexts:"),
        for({name, path} <- build.contexts, do: "        - #{name}=#{path}")
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    "#{params.version_prefix}services:\n  #{scalar(params.service)}:\n#{Enum.join(lines, "\n")}\n\n"
  end

  @doc """
  The override the container is created with. `:image` replaces the
  service's (nil keeps it); `:entrypoints` are the features'; `:command`
  is `:keep` or the command to give; `:mounts` are as a config has them,
  strings or maps.
  """
  @spec start_override(map()) :: String.t()
  def start_override(params) do
    mounts = Enum.map(params.mounts, &Metadata.parse_mount/1)
    env = for {key, value} <- Enum.sort(params.env), do: quoted("#{key}=#{env_value(value)}")

    IO.iodata_to_binary([
      params.version_prefix,
      "services:\n  '",
      params.service,
      "':",
      field("image", params.image && scalar(params.image)),
      entrypoint(params.entrypoints, params.user_entrypoint),
      command(params.command),
      flag("init", params.init),
      field("user", params.user && scalar(params.user)),
      section("environment", env),
      flag("privileged", params.privileged),
      section("cap_add", Enum.map(params.cap_add, &scalar/1)),
      section("security_opt", Enum.map(params.security_opt, &scalar/1)),
      section("labels", Enum.map(params.labels, &quoted/1)),
      section("volumes", Enum.map(mounts, &scalar(volume(&1)))),
      named_volumes(Enum.filter(mounts, &(&1["type"] == "volume" and truthy?(&1["source"])))),
      "\n"
    ])
  end

  # The features' entrypoints run first, then whatever the container was
  # going to run, and the container stays up after it.
  defp entrypoint(entrypoints, user_entrypoint) do
    script =
      "echo Container started\\n\n" <>
        "trap \\\"exit 0\\\" 15\\n\n" <>
        Enum.map_join(entrypoints, "\\n\n", &in_double_quotes/1) <>
        "\\n\n" <>
        "exec \\\"$$@\\\"\\n\n" <>
        "while sleep 1 & wait $$!; do :; done"

    [
      "\n    entrypoint: [\"/bin/sh\", \"-c\", \"",
      script,
      "\", \"-\"",
      Enum.map(user_entrypoint, &[", ", JSON.encode!(&1)]),
      "]"
    ]
  end

  # A feature's entrypoint, inside the YAML string the script is.
  defp in_double_quotes(text),
    do: text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp command(:keep), do: []
  defp command(command), do: ["\n    command: ", JSON.encode!(command)]

  defp field(_name, nil), do: []
  defp field(name, value), do: ["\n    ", name, ": ", value]

  defp flag(name, true), do: ["\n    ", name, ": true"]
  defp flag(_name, _value), do: []

  defp named_volumes([]), do: []

  defp named_volumes(mounts) do
    [
      "\nvolumes:"
      | Enum.map(mounts, &["\n  \n  ", scalar(&1["source"]), ":", external(&1["external"])])
    ]
  end

  defp external(value), do: if(truthy?(value), do: "\n    external: true", else: [])

  defp section(_name, []), do: []
  defp section(name, items), do: ["\n    ", name, ":", Enum.map(items, &["\n      - ", &1])]

  # A single-quoted YAML scalar that compose won't interpolate.
  defp quoted(text),
    do: ["'", text |> String.replace("$", "$$") |> String.replace("'", "''"), "'"]

  defp env_value(value) when is_binary(value), do: String.replace(value, "\n", "\\n")
  defp env_value(nil), do: "null"
  defp env_value(value), do: env_value(to_string(value))

  # A value as YAML reads it back: plain, as the devcontainer CLI writes
  # it, unless YAML would take it for something else (a comment after
  # " #", a mapping at ": ", an alias, a list item), which is quoted.
  # Compose still interpolates a `$` either way, as it always did here.
  defp scalar(value) do
    text = to_string(value)

    if Regex.match?(~r/\A[A-Za-z0-9_.\/$+=-][^\n\r\t]*\z/, text) and
         not String.contains?(text, [": ", " #"]) and
         not String.starts_with?(text, "- ") and
         not String.ends_with?(text, [":", " "]) and
         not typed?(text),
       do: text,
       else: JSON.encode!(text)
  end

  # What YAML reads as a number, a boolean or nothing rather than as text.
  defp typed?(text) do
    Regex.match?(~r/\A(null|true|false|yes|no|on|off|y|n|-)\z/i, text) or
      Regex.match?(
        ~r/\A[-+]?(\d[\d_:.]*([eE][-+]?\d+)?|0x[0-9a-fA-F_]+|0o[0-7_]+|0b[01_]+|\.\d+|\.inf|\.nan)\z/i,
        text
      )
  end

  defp volume(mount) do
    if truthy?(mount["source"]),
      do: "#{mount["source"]}:#{mount["target"]}",
      else: "#{mount["target"]}"
  end

  defp truthy?(value), do: value not in [nil, false, ""]
end
