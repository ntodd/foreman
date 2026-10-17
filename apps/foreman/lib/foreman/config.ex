defmodule Foreman.Config do
  @moduledoc "Deployment settings read from the application environment."

  @doc "The control plane's external base URL, e.g. https://foreman.tail1234.ts.net."
  def base_url do
    case Application.get_env(:foreman, :base_url) do
      url when is_binary(url) -> String.trim_trailing(url, "/")
      _ -> endpoint_url()
    end
  end

  defp endpoint_url do
    config = Application.get_env(:foreman, ForemanWeb.Endpoint, [])
    url = config[:url] || []
    scheme = url[:scheme] || "http"
    host = url[:host] || "localhost"
    port = url[:port] || get_in(config, [:http, :port]) || 4000

    default_port? = (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
    if default_port?, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  def slug_style, do: Application.get_env(:foreman, :slug_style, :personal)

  def git_base_url,
    do:
      Application.get_env(:foreman, :git_base_url, "https://github.com")
      |> String.trim_trailing("/")

  @doc "The VM size for an environment on a VM box that nothing else sizes."
  def vm_default_size do
    %{
      cpus: Application.get_env(:foreman, :vm_default_cpus, 4),
      memory_mb: Application.get_env(:foreman, :vm_default_memory_mb, 8192)
    }
  end
end
