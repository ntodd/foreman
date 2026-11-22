defmodule ForemanWeb.EnvironmentConnection do
  @moduledoc "Formats connection details for a shell or editor from a stored environment."

  def account?(user), do: is_binary(user) and user =~ ~r/\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/

  def workspace?(path),
    do:
      is_binary(path) and String.starts_with?(path, "/") and
        not Regex.match?(~r/[[:cntrl:]]/, path)

  def exec_command(env) do
    if account?(env.remote_user) and workspace?(env.workspace_folder) and
         is_binary(env.devcontainer_service) and
         env.devcontainer_service =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/ do
      path = "'" <> String.replace(env.workspace_folder, "'", "'\\''") <> "'"

      "docker exec -it -u #{env.remote_user} -w #{path} #{env.slug}-#{env.devcontainer_service}-1 bash -l"
    end
  end

  def editor_path(path), do: URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))
end
