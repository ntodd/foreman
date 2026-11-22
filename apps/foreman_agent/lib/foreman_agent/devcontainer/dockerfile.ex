defmodule ForemanAgent.Devcontainer.Dockerfile do
  @moduledoc """
  As much of a Dockerfile as building a devcontainer on top of one needs:
  its stages, the image the built stage starts from, the user it ends as,
  and a name for its last stage. It reads `FROM`, `ARG`, `ENV` and `USER`
  the way the devcontainer CLI does, so the same Dockerfiles give the same
  answers.
  """

  @from ~r/^\s*FROM\s+(?<platform>--platform=\S+\s+)?(?<image>"?[^\s]+"?)(\s+AS\s+(?<label>[^\s]+))?/mi
  @from_ahead ~r/(?=^[\t ]*FROM)/mi
  @instruction ~r/^\s*(ARG|ENV|USER)\s+([^\s=]+)(?:[ =]+(?:"(\S+)"|(\S+)))?/mi
  @directive ~r/^\s*#\s*(\S+)\s*=\s*(.+)/
  @syntax_version ~r/^(?:docker.io\/)?docker\/dockerfile(?::(\S+))?/i
  @variable ~r/\$\{?([a-zA-Z0-9_]+)(:(-|\+)([^\}]+))?\}?/

  @from_lines ~r/^(\s*FROM.*)/mi
  @from_line ~r/FROM\s+(--platform=\S+\s+)?("?[^\s]+"?)(\s+AS\s+([^\s]+))?/i

  @type instruction :: %{instruction: String.t(), name: String.t(), value: String.t() | nil}
  @type stage :: %{
          from: %{image: String.t(), label: String.t() | nil},
          instructions: [instruction()]
        }
  @type t :: %{
          preamble: %{
            version: String.t() | nil,
            directives: %{String.t() => String.t()},
            instructions: [instruction()]
          },
          stages: [stage()],
          stages_by_label: %{String.t() => stage()}
        }

  @spec parse(String.t()) :: t()
  def parse(text) do
    {preamble, stages} =
      case Regex.split(@from_ahead, text) do
        [first | rest] = parts ->
          if Regex.match?(~r/\A[\t ]*FROM/i, first), do: {"", parts}, else: {first, rest}

        [] ->
          {"", []}
      end

    stages = for stage <- stages, do: %{from: from(stage), instructions: instructions(stage)}
    directives = directives(preamble)

    %{
      preamble: %{
        version: syntax_version(directives["syntax"]),
        directives: directives,
        instructions: instructions(preamble)
      },
      stages: stages,
      stages_by_label:
        for(
          %{from: %{label: label}} = stage when is_binary(label) <- stages,
          into: %{},
          do: {label, stage}
        )
    }
  end

  @doc """
  The image the target stage (the last one, without a target) is built
  from, through any stages in between. Nil when the stages lead nowhere.
  """
  @spec find_base_image(t(), map(), String.t() | nil, map()) :: String.t() | nil
  def find_base_image(dockerfile, build_args, target, platform_args \\ %{}) do
    scope = %{
      dockerfile: dockerfile,
      build_args: build_args,
      base_env: %{},
      platform_args: platform_args
    }

    base_image(scope, start(dockerfile, target), [])
  end

  defp base_image(_scope, nil, _seen), do: nil

  defp base_image(scope, stage, seen) do
    if stage in seen do
      nil
    else
      image = stage_image(scope, stage)

      case scope.dockerfile.stages_by_label[image] do
        nil -> image
        next -> base_image(scope, next, [stage | seen])
      end
    end
  end

  @doc """
  The user the target stage ends as: its last `USER`, or that of the stage
  it's built on. Nil when no stage sets one (the base image's applies).
  """
  @spec find_user(t(), map(), map(), map(), String.t() | nil) :: String.t() | nil
  def find_user(dockerfile, build_args, base_image_env, platform_args, target) do
    scope = %{
      dockerfile: dockerfile,
      build_args: build_args,
      base_env: base_image_env,
      platform_args: platform_args
    }

    user(scope, start(dockerfile, target), [])
  end

  defp user(_scope, nil, _seen), do: nil

  defp user(scope, stage, seen) do
    if stage in seen do
      nil
    else
      case last_index(
             stage.instructions,
             &(&1.instruction == "USER"),
             length(stage.instructions) - 1
           ) do
        nil ->
          user(scope, scope.dockerfile.stages_by_label[stage_image(scope, stage)], [stage | seen])

        index ->
          name = Enum.at(stage.instructions, index).name

          case replace_variables(scope, name, stage, index) do
            "" -> nil
            user -> user
          end
      end
    end
  end

  @doc """
  The name of the last stage. One without a name gets `default`, and the
  Dockerfile comes back with it added.
  """
  @spec ensure_final_stage_name(String.t(), String.t()) ::
          {:ok, String.t(), String.t() | nil} | {:error, String.t()}
  def ensure_final_stage_name(text, default) do
    case Regex.scan(@from_lines, text, return: :index, capture: :first) do
      [] ->
        {:error, "the Dockerfile has no FROM instruction"}

      lines ->
        [{line_start, line_length}] = List.last(lines)
        line = binary_part(text, line_start, line_length)

        case Regex.run(@from_line, line, return: :index) do
          nil ->
            {:error, "couldn't read the Dockerfile's last FROM line"}

          [_, _, _, _, {label_start, label_length}] ->
            {:ok, binary_part(line, label_start, label_length), nil}

          [{start, length} | _] ->
            at = line_start + start + length

            {:ok, default,
             binary_part(text, 0, at) <>
               " AS " <> default <> binary_part(text, at, byte_size(text) - at)}
        end
    end
  end

  @doc """
  Whether the Dockerfile's syntax directive names a frontend with build
  contexts (docker/dockerfile 1.4 on). `:unknown` for someone else's
  frontend, false without a directive.
  """
  @spec supports_build_contexts(t()) :: boolean() | :unknown
  def supports_build_contexts(%{preamble: %{version: nil, directives: directives}}),
    do: if(directives["syntax"], do: :unknown, else: false)

  def supports_build_contexts(%{preamble: %{version: version}}),
    do: supports_context_version?(version)

  @doc "Syntax directive for a build that mounts features from a named context."
  def feature_syntax(syntax) do
    version = syntax_version(syntax)

    if version && !supports_context_version?(version) do
      if String.contains?(version, "-labs"),
        do: "docker/dockerfile:1.4-labs",
        else: "docker/dockerfile:1.4"
    else
      syntax
    end
  end

  defp supports_context_version?(version) do
    case Regex.run(~r/^\d+(\.\d+){0,2}/, version) do
      nil ->
        # latest, labs or no tag.
        true

      [numbers | _] ->
        case numbers |> String.split(".") |> Enum.map(&String.to_integer/1) do
          [major] -> major >= 1
          [major, minor | _] -> {major, minor} >= {1, 4}
        end
    end
  end

  defp start(dockerfile, nil), do: List.last(dockerfile.stages)
  defp start(dockerfile, target), do: dockerfile.stages_by_label[target]

  # A stage's FROM sees only the ARGs before the first FROM.
  defp stage_image(scope, stage) do
    preamble = scope.dockerfile.preamble
    replace_variables(scope, stage.from.image, preamble, length(preamble.instructions))
  end

  defp from(stage) do
    case Regex.named_captures(@from, stage) do
      nil ->
        %{image: "unknown", label: nil}

      %{"image" => image, "label" => label} ->
        %{image: Regex.replace(~r/^['"]|['"]$/, image, ""), label: if(label != "", do: label)}
    end
  end

  defp instructions(text) do
    for [_, instruction, name | values] <- Regex.scan(@instruction, text) do
      %{
        instruction: String.upcase(instruction),
        name: name,
        value: Enum.find(values, &(&1 != ""))
      }
    end
  end

  defp directives(preamble) do
    preamble
    |> String.split(~r/\r?\n/)
    |> Enum.reduce_while(%{}, fn line, acc ->
      case Regex.run(@directive, line) do
        [_, name, value] -> {:cont, Map.put_new(acc, name, value)}
        nil -> {:halt, acc}
      end
    end)
  end

  defp syntax_version(nil), do: nil

  defp syntax_version(syntax) do
    case Regex.run(@syntax_version, syntax) do
      nil -> nil
      [_] -> "latest"
      [_, version] -> version
    end
  end

  # `holder` is a stage or the preamble; only instructions before `before`
  # in it count.
  defp replace_variables(_scope, nil, _holder, _before), do: ""

  defp replace_variables(scope, string, holder, before) do
    Regex.replace(@variable, string, fn _match, variable, expression, option, word ->
      value = find_value(scope, variable, holder, before, true, []) || ""

      if expression == "" do
        value
      else
        chosen =
          case {option, value != ""} do
            {"-", true} -> value
            {"-", false} -> word
            {"+", true} -> word
            {"+", false} -> value
          end

        Regex.replace(~r/^['"]|['"]$/, chosen, "")
      end
    end)
  end

  defp find_value(scope, variable, holder, before, consider_arg?, seen) do
    if holder in seen do
      nil
    else
      found =
        last_index(
          holder.instructions,
          fn i ->
            i.name == variable and
              (i.instruction == "ENV" or
                 (consider_arg? and is_binary(Map.get(scope.build_args, i.name, i.value))))
          end,
          before - 1
        )

      case found && Enum.at(holder.instructions, found) do
        %{instruction: "ENV", value: value} ->
          replace_variables(scope, value, holder, found)

        %{instruction: "ARG", name: name, value: value} ->
          replace_variables(scope, Map.get(scope.build_args, name, value), holder, found)

        _ ->
          outer_value(scope, variable, holder, seen)
      end
    end
  end

  # Past a stage's own instructions: the stage it's built on (ENVs carry
  # over, ARGs don't), then the ARGs before the first FROM, then the base
  # image's environment and BuildKit's platform arguments.
  defp outer_value(scope, variable, %{from: _} = stage, seen) do
    preamble = scope.dockerfile.preamble

    case scope.dockerfile.stages_by_label[stage_image(scope, stage)] do
      nil ->
        find_value(scope, variable, preamble, length(preamble.instructions), true, [stage | seen])

      next ->
        find_value(scope, variable, next, length(next.instructions), false, [stage | seen])
    end
  end

  defp outer_value(scope, variable, _preamble, _seen) do
    case Map.get(scope.base_env, variable, scope.platform_args[variable]) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp last_index(list, predicate, position) do
    list
    |> Enum.take(max(position + 1, 0))
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {item, index} -> if predicate.(item), do: index end)
  end
end
