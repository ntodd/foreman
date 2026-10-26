defmodule ForemanProtocol.Schema do
  @moduledoc """
  A small, strict validator for protocol payloads.

  A spec is a keyword list of `field: {type, opts}`. Casting turns a map
  with string (wire) or atom keys into a map with atom keys, and rejects
  anything the spec doesn't name. Dumping turns it back into string keys.

  The validator is deliberately conservative: values from the wire end up
  in file names, argv and compose files on the agent, so every type is
  as narrow as the agent's use of it.

  Options: `required: true`, `default: value`.
  """

  @type error :: {String.t(), String.t()}
  @type spec :: keyword({atom() | tuple(), keyword()})

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slug ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @repo ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @service ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/
  @version ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z.]{1,32})?\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @ts_tag ~r/\Atag:[A-Za-z0-9][A-Za-z0-9-]{0,62}\z/
  @hostname ~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::\d{1,5})?\z/
  @option_name ~r/\A[A-Za-z0-9_][A-Za-z0-9_-]{0,127}\z/

  # Names the agent sets itself on the processes it runs. A payload must
  # not be able to override them (or inject a loader).
  @reserved_env ~w(PATH HOME USER SHELL DOCKER_HOST DOCKER_CONFIG DOCKER_CONTEXT
                   DOCKER_CERT_PATH DOCKER_TLS_VERIFY COMPOSE_PROJECT_NAME COMPOSE_FILE
                   COMPOSE_PROFILES COMPOSE_ENV_FILES GIT_DIR GIT_WORK_TREE GIT_CONFIG_GLOBAL
                   GIT_CONFIG_SYSTEM GIT_ASKPASS GIT_SSH GIT_SSH_COMMAND NODE_OPTIONS
                   LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV TMPDIR)

  @max_text 1_048_576

  @doc "File names the agent will write into an environment's secrets directory."
  def secret_files, do: ~w(secrets.env github-token ts-authkey gitconfig notices)

  def reserved_env, do: @reserved_env

  @spec cast(term(), spec()) :: {:ok, map()} | {:error, [error()]}
  def cast(input, spec) when is_map(input) do
    case cast_object(input, spec, "") do
      {:ok, value} -> {:ok, value}
      {:error, errors} -> {:error, errors}
    end
  end

  def cast(_input, _spec), do: {:error, [{"", "must be an object"}]}

  @spec dump(map(), spec()) :: map()
  def dump(value, spec) when is_map(value) do
    Enum.reduce(spec, %{}, fn {field, {type, _opts}}, acc ->
      case Map.fetch(value, field) do
        {:ok, v} -> Map.put(acc, Atom.to_string(field), dump_value(v, type))
        :error -> acc
      end
    end)
  end

  defp dump_value(v, {:object, spec}), do: dump(v, spec)
  defp dump_value(v, {:list, type}), do: Enum.map(v, &dump_value(&1, type))

  defp dump_value(v, {:map_of, _key, type}),
    do: Map.new(v, fn {k, x} -> {k, dump_value(x, type)} end)

  defp dump_value(v, _type), do: v

  defp cast_object(input, spec, prefix) do
    known = MapSet.new(spec, fn {field, _} -> Atom.to_string(field) end)

    unknown_errors =
      input
      |> Map.keys()
      |> Enum.map(&key_to_string/1)
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&{path(prefix, &1), "is not allowed"})

    {values, errors} =
      Enum.reduce(spec, {%{}, unknown_errors}, fn {field, {type, opts}}, {acc, errs} ->
        name = Atom.to_string(field)
        p = path(prefix, name)

        case fetch(input, field, name) do
          {:ok, nil} -> missing(acc, errs, field, type, opts, p)
          {:ok, raw} -> put_cast(acc, errs, field, cast_value(raw, type, p))
          :error -> missing(acc, errs, field, type, opts, p)
        end
      end)

    case errors do
      [] -> {:ok, values}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp missing(acc, errs, field, type, opts, p) do
    cond do
      Keyword.has_key?(opts, :default) ->
        put_cast(acc, errs, field, cast_value(Keyword.fetch!(opts, :default), type, p))

      Keyword.get(opts, :required, false) ->
        {acc, [{p, "is required"} | errs]}

      true ->
        {acc, errs}
    end
  end

  defp put_cast(acc, errs, field, {:ok, v}), do: {Map.put(acc, field, v), errs}
  defp put_cast(acc, errs, _field, {:error, more}), do: {acc, Enum.reverse(more) ++ errs}

  defp fetch(input, field, name) do
    case Map.fetch(input, name) do
      {:ok, v} -> {:ok, v}
      :error -> Map.fetch(input, field)
    end
  end

  defp key_to_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_to_string(k) when is_binary(k), do: k
  defp key_to_string(k), do: inspect(k)

  defp path("", name), do: name
  defp path(prefix, name), do: prefix <> "." <> name

  defp err(p, msg), do: {:error, [{p, msg}]}

  # -- types -----------------------------------------------------------

  defp cast_value(v, {:object, spec}, p) when is_map(v), do: cast_object(v, spec, p)
  defp cast_value(_v, {:object, _}, p), do: err(p, "must be an object")

  defp cast_value(v, {:list, type}, p) when is_list(v) do
    v
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {item, i}, {ok, errs} ->
      case cast_value(item, type, p) do
        {:ok, x} ->
          {[x | ok], errs}

        {:error, e} ->
          # Prepended in reverse and flipped once at the end: appending
          # here would be quadratic in the number of bad items.
          {ok, Enum.reduce(e, errs, fn {ep, m}, acc -> [{ep, "item #{i} #{m}"} | acc] end)}
      end
    end)
    |> case do
      {ok, []} -> {:ok, Enum.reverse(ok)}
      {_, errs} -> {:error, Enum.reverse(errs)}
    end
  end

  defp cast_value(_v, {:list, _}, p), do: err(p, "must be a list")

  defp cast_value(v, {:map_of, key_type, value_type}, p) when is_map(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn {k, x}, {:ok, acc} ->
      with {:ok, key} <- cast_value(key_to_string(k), key_type, p),
           {:ok, value} <- cast_value(x, value_type, path(p, key)) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp cast_value(_v, {:map_of, _, _}, p), do: err(p, "must be an object")

  defp cast_value(v, {:enum, values}, p) do
    if v in values, do: {:ok, v}, else: err(p, "must be one of: #{Enum.join(values, ", ")}")
  end

  defp cast_value(v, :string, p) when is_binary(v) do
    cond do
      v == "" -> err(p, "can't be blank")
      byte_size(v) > 4096 -> err(p, "is too long")
      not String.valid?(v) -> err(p, "must be UTF-8")
      String.contains?(v, <<0>>) -> err(p, "must not contain NUL bytes")
      true -> {:ok, v}
    end
  end

  # Text goes over a JSON wire, which can't carry bytes that aren't
  # UTF-8; senders replace them (`String.replace_invalid/1`) first.
  defp cast_value(v, :text, p) when is_binary(v) do
    cond do
      byte_size(v) > @max_text -> err(p, "is too long")
      not String.valid?(v) -> err(p, "must be UTF-8")
      String.contains?(v, <<0>>) -> err(p, "must not contain NUL bytes")
      true -> {:ok, v}
    end
  end

  defp cast_value(v, :boolean, _p) when is_boolean(v), do: {:ok, v}
  defp cast_value(_v, :boolean, p), do: err(p, "must be a boolean")

  defp cast_value(v, :integer, _p) when is_integer(v) and v >= 0, do: {:ok, v}
  defp cast_value(_v, :integer, p), do: err(p, "must be a non-negative integer")

  defp cast_value(v, :port, _p) when is_integer(v) and v in 1..65_535, do: {:ok, v}
  defp cast_value(_v, :port, p), do: err(p, "must be a port number")

  # A process name the agent read inside an environment, which the
  # environment controls: short, and nothing that draws on a terminal.
  defp cast_value(v, :process, p) when is_binary(v) do
    cond do
      v == "" -> err(p, "can't be blank")
      byte_size(v) > 64 -> err(p, "is too long")
      not String.valid?(v) -> err(p, "must be UTF-8")
      String.match?(v, ~r/[[:cntrl:]]/u) -> err(p, "must not contain control characters")
      true -> {:ok, v}
    end
  end

  defp cast_value(v, :positive_number, _p) when is_number(v) and v > 0, do: {:ok, v}
  defp cast_value(_v, :positive_number, p), do: err(p, "must be a positive number")

  defp cast_value(v, :number, _p) when is_number(v) and v >= 0, do: {:ok, v}
  defp cast_value(_v, :number, p), do: err(p, "must be a non-negative number")

  defp cast_value(v, :json, _p) when is_map(v), do: {:ok, v}
  defp cast_value(_v, :json, p), do: err(p, "must be an object")

  defp cast_value(v, :uuid, p), do: match(v, @uuid, p, "must be a UUID")
  defp cast_value(v, :slug, p), do: match(v, @slug, p, "must be a lowercase DNS label")

  defp cast_value(v, :service_name, p),
    do: match(v, @service, p, "must be a compose service name")

  defp cast_value(v, :env_name, p), do: match(v, @env_name, p, "must be a variable name")

  defp cast_value(v, :version, p), do: match(v, @version, p, "must be a version like 1.2.3")
  defp cast_value(v, :sha256, p), do: match(v, @sha256, p, "must be a lowercase hex SHA-256")
  defp cast_value(v, :ts_tag, p), do: match(v, @ts_tag, p, "must be a Tailscale tag")
  defp cast_value(v, :hostname, p), do: match(v, @hostname, p, "must be a host name")

  defp cast_value(v, :option_name, p),
    do: match(v, @option_name, p, "must be a feature option name")

  defp cast_value(v, :feature_ref, p) do
    if ForemanProtocol.Feature.valid_ref?(v),
      do: {:ok, v},
      else: err(p, "must be a feature ref like ghcr.io/owner/features/name:1")
  end

  # Feature options are strings or booleans, as devcontainer.json has them.
  defp cast_value(v, :feature_option, _p) when is_boolean(v), do: {:ok, v}
  defp cast_value("", :feature_option, _p), do: {:ok, ""}
  defp cast_value(v, :feature_option, p), do: cast_value(v, :string, p)

  defp cast_value(v, :repo, p) do
    with {:ok, v} <- match(v, @repo, p, "must look like owner/name") do
      [_, name] = String.split(v, "/")
      if name in [".", ".."], do: err(p, "must look like owner/name"), else: {:ok, v}
    end
  end

  defp cast_value(v, :base64, p) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, _} -> {:ok, v}
      :error -> err(p, "must be base64")
    end
  end

  # URI parsing and charlist conversion raise on bytes that aren't UTF-8.
  defp cast_value(v, type, p)
       when type in [:git_url, :https_url, :url, :git_ref, :relative_path] and is_binary(v) do
    if String.valid?(v), do: cast_utf8(v, type, p), else: err(p, "must be UTF-8")
  end

  defp cast_value(v, :files, p) when is_map(v) do
    allowed = secret_files()

    Enum.reduce_while(v, {:ok, %{}}, fn {name, content}, {:ok, acc} ->
      name = key_to_string(name)

      cond do
        name not in allowed ->
          {:halt, err(p, "contains a file name that is not allowed: #{name}")}

        not is_binary(content) ->
          {:halt, err(p, "#{name} must be a string")}

        true ->
          content |> cast_value(:text, path(p, name)) |> put_file(acc, name)
      end
    end)
  end

  defp cast_value(v, :env_map, p) when is_map(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      name = key_to_string(name)

      cond do
        not Regex.match?(@env_name, name) ->
          {:halt, err(p, "contains an invalid variable name: #{name}")}

        name in @reserved_env or String.starts_with?(name, "FOREMAN_") ->
          {:halt, err(p, "contains a reserved variable name: #{name}")}

        not is_binary(value) or not String.valid?(value) or String.contains?(value, <<0>>) ->
          {:halt, err(p, "#{name} must be a UTF-8 string without NUL bytes")}

        true ->
          {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp cast_value(_v, type, p) when type in [:files, :env_map], do: err(p, "must be an object")
  defp cast_value(_v, _type, p), do: err(p, "must be a string")

  defp cast_utf8(v, :git_url, p), do: cast_url(v, p, ["https", "http"])
  defp cast_utf8(v, :https_url, p), do: cast_url(v, p, ["https"])
  defp cast_utf8(v, :url, p), do: cast_url(v, p, ["https", "http"])
  defp cast_utf8(v, :git_ref, p), do: cast_git_ref(v, p)
  defp cast_utf8(v, :relative_path, p), do: cast_relative_path(v, p)

  defp match(v, regex, p, msg) when is_binary(v) do
    if Regex.match?(regex, v), do: {:ok, v}, else: err(p, msg)
  end

  defp match(_v, _regex, p, _msg), do: err(p, "must be a string")

  defp cast_url(v, p, schemes) do
    case URI.new(v) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        cond do
          scheme not in schemes -> err(p, "must use #{Enum.join(schemes, " or ")}")
          String.contains?(v, [" ", "\n", "\r", "\t"]) -> err(p, "must not contain whitespace")
          true -> {:ok, v}
        end

      {:ok, %URI{userinfo: info}} when is_binary(info) ->
        err(p, "must not contain credentials")

      _ ->
        err(p, "must be a URL")
    end
  end

  defp put_file({:ok, content}, acc, name), do: {:cont, {:ok, Map.put(acc, name, content)}}
  defp put_file(error, _acc, _name), do: {:halt, error}

  # git-check-ref-format rules, plus: no leading "-" (it would be read as
  # an option), and a length cap.
  defp cast_git_ref(v, p) do
    if valid_ref_shape?(v) and valid_ref_chars?(v),
      do: {:ok, v},
      else: err(p, "must be a valid branch name")
  end

  defp valid_ref_shape?(v) do
    v != "" and v != "@" and byte_size(v) <= 255 and
      not String.starts_with?(v, ["-", "/", "."]) and
      not String.ends_with?(v, ["/", ".", ".lock"]) and
      not Enum.any?(
        String.split(v, "/"),
        &(String.starts_with?(&1, ".") or String.ends_with?(&1, ".lock"))
      )
  end

  defp valid_ref_chars?(v) do
    not String.contains?(v, ["..", "//", "@{", "\\", " ", "~", "^", ":", "?", "*", "["]) and
      not Enum.any?(String.to_charlist(v), &(&1 < 32 or &1 == 127))
  end

  defp cast_relative_path(v, p) do
    segments = String.split(v, "/")

    cond do
      v == "" or byte_size(v) > 512 ->
        err(p, "must be a relative path")

      String.starts_with?(v, "/") ->
        err(p, "must be a relative path inside the repository")

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        err(p, "must be a relative path inside the repository")

      String.contains?(v, [<<0>>, "\\", "\n"]) ->
        err(p, "must be a relative path")

      String.starts_with?(v, "-") ->
        err(p, "must be a relative path")

      true ->
        {:ok, v}
    end
  end
end
