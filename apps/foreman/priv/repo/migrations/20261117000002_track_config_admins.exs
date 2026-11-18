defmodule Foreman.Repo.Migrations.TrackConfigAdmins do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:users) do
      add :admin_via_config, :boolean, null: false, default: false
    end

    flush()
    admins = Enum.map(Application.get_env(:foreman, :admins, []), &String.downcase/1)

    # Existing rows don't record why someone became admin. Keep explicit
    # People-page promotions local, even for a login also in FOREMAN_ADMINS.
    users =
      from(u in "users",
        where: u.role == "admin" and fragment("lower(?)", u.login) in ^admins,
        select: type(u.id, :binary_id)
      )

    for id <- repo().all(users) do
      grants =
        from(e in "audit_events",
          where: e.action == "user.role" and e.subject_type == "User" and e.subject_id == ^id,
          order_by: [desc: e.inserted_at],
          select: type(e.metadata, :map)
        )

      if Enum.find_value(repo().all(grants), & &1["role"]) != "admin" do
        query =
          from(u in "users",
            where: u.id == type(^id, :binary_id),
            update: [set: [admin_via_config: fragment("TRUE")]]
          )

        repo().update_all(query, [])
      end
    end
  end

  def down do
    alter table(:users) do
      remove :admin_via_config
    end
  end
end
