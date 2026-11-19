defmodule ForemanProtocol.VMSize do
  @moduledoc "The cold-boot allocation used by both VM launch and placement."
  def resolve(limits, defaults, box) do
    cpus =
      case limits do
        %{cpus: cpus} when is_number(cpus) and cpus > 0 -> ceil(cpus)
        _ -> defaults.cpus
      end

    memory =
      case limits do
        %{memory_mb: mb} when is_integer(mb) and mb > 0 -> mb
        _ -> defaults.memory_mb
      end

    %{
      cpus: cpus |> min(box.cpus) |> max(1),
      memory_mb: memory |> min(box.memory_mb) |> max(512)
    }
  end
end
