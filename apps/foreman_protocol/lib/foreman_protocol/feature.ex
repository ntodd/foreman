defmodule ForemanProtocol.Feature do
  @moduledoc """
  Devcontainer feature refs a user adds to their own environments.

  Only OCI refs (`ghcr.io/owner/features/name:1`): a local path would
  resolve against the repo's devcontainer folder, and a tarball URL skips
  the registry. A tag isn't locked the way a repo's lock file locks it.

  Narrower than OCI allows, to match the devcontainer CLI's parser: it
  wants a namespace and an id, takes one separator between characters,
  and lowercases the whole ref (a tag with capitals would become another
  tag).
  """

  @component "[a-z0-9]+(?:[._-][a-z0-9]+)*"
  @host "(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+|localhost)(?::\\d{1,5})?"
  @version "(?::[a-z0-9_][a-z0-9._-]{0,127}|@sha256:[a-f0-9]{64})?"
  @ref Regex.compile!("\\A#{@host}(?:/#{@component}){2,}#{@version}\\z")

  @max_ref 512

  @doc "The id of the feature Foreman installs in every environment. Nothing else can use it."
  def foreman_id, do: "foreman"

  @doc "The `ForemanProtocol.Schema` type of a set of features: ref => options."
  def type, do: {:map_of, :feature_ref, options_type()}

  @doc "The `ForemanProtocol.Schema` type of one feature's options."
  def options_type, do: {:map_of, :option_name, :feature_option}

  @doc "Whether `ref` is an OCI feature ref."
  def valid_ref?(ref) when is_binary(ref),
    do: byte_size(ref) <= @max_ref and Regex.match?(@ref, ref)

  def valid_ref?(_), do: false

  @doc "The ref without its tag or digest: the same feature at any version."
  def base(ref) do
    case String.split(ref, "@", parts: 2) do
      [base, _digest] ->
        base

      [ref] ->
        {path, name} = split_last(ref)

        case String.split(name, ":", parts: 2) do
          [name, _tag] -> path <> name
          [_] -> ref
        end
    end
  end

  @doc "The feature's id: the last part of its ref."
  def id(ref), do: ref |> base() |> split_last() |> elem(1)

  defp split_last(ref) do
    case :binary.matches(ref, "/") do
      [] ->
        {"", ref}

      matches ->
        {pos, 1} = List.last(matches)
        {binary_part(ref, 0, pos + 1), binary_part(ref, pos + 1, byte_size(ref) - pos - 1)}
    end
  end
end
