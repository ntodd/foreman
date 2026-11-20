defmodule Foreman.Repo.Migrations.AddLastVmOomAt do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :last_vm_oom_at, :utc_datetime
    end
  end
end
