defmodule ForemanWeb.PublicReadController do
  use ForemanWeb, :controller

  import Ecto.Query

  alias Foreman.{Boxes, Repo}
  alias Foreman.Operations.{LogStore, Retention}
  alias Foreman.PublicAPI.{Access, Readiness}
  alias ForemanWeb.{EnvironmentConnection, PublicCursor}

  @page_size 50
  @environment_fields ~w(id slug repo_id branch box_id desired_state observed_state)a
  @observations ~w(expiry_at expiry_action workspace_container_id created_once tailscale_device_id remote_user workspace_folder)a
  @operation_fields ~w(id environment_id action trigger status error timeout_error inserted_at finished_at log_truncated)a

  def repos(conn, params) do
    collection(conn, params, "repos:list", fn p ->
      {select(Access.repos(p), [r], map(r, [:id, :full_name, :default_branch])), :full_name,
       &Function.identity/1}
    end)
  end

  def boxes(conn, params) do
    collection(conn, params, "boxes:list", fn p ->
      {select(Access.boxes(p), [b], map(b, [:id, :name])), :name,
       fn b -> Map.put(b, :online, Boxes.online?(b.id)) end}
    end)
  end

  def environments(conn, params) do
    collection(conn, params, "environments:list", fn p ->
      {live(Access.environments(p)), :id, &environment_json(&1, p)}
    end)
  end

  def environment(conn, %{"id" => raw_id}) do
    p = conn.assigns.api_principal

    result =
      with {:ok, id} <- uuid(raw_id),
           {:ok, env} <- find_one(live(Access.environments(p, id))),
           :ok <- permit(p, "environments:read") do
        {:ok, environment_json(env, p)}
      end

    respond(conn, result)
  end

  def operations(conn, %{"id" => raw_id} = params) do
    p = conn.assigns.api_principal

    result =
      with {:ok, id} <- uuid(raw_id),
           :ok <- visible(p, id),
           :ok <- permit(p, "operations:list") do
        query = from o in history(), where: o.environment_id == ^id
        page(query, :inserted_at, &operation_json/1, p, {:operations, id}, params)
      end

    respond(conn, result)
  end

  def operation(conn, %{"id" => raw_id}) do
    result =
      with {:ok, op} <- authorized_op(conn.assigns.api_principal, raw_id, "operations:read") do
        {:ok, operation_json(op)}
      end

    respond(conn, result)
  end

  def logs(conn, %{"id" => raw_id} = params) do
    p = conn.assigns.api_principal

    result =
      with {:ok, op} <- authorized_op(p, raw_id, "logs:read"),
           context = PublicCursor.context(p, {:logs, op.id}),
           {:ok, offset} <- PublicCursor.decode(context, params["cursor"]) do
        {text, next, truncated} = LogStore.page(op, offset || 0)

        cursor = if offset == next, do: params["cursor"], else: PublicCursor.encode(context, next)
        {:ok, %{text: text, next_cursor: cursor, truncated: truncated}}
      end

    respond(conn, result)
  end

  defp authorized_op(p, raw_id, scope) do
    query = if scope == "logs:read", do: log_history(), else: history()

    with {:ok, id} <- uuid(raw_id),
         {:ok, op} <- find_one(where(query, [o], o.id == ^id)),
         :ok <- visible(p, op.environment_id),
         :ok <- permit(p, scope) do
      {:ok, op}
    end
  end

  defp history do
    from o in Retention.history(DateTime.utc_now()), select: map(o, ^@operation_fields)
  end

  defp log_history do
    cutoff = Retention.log_cutoff(DateTime.utc_now())
    from o in history(), where: is_nil(o.finished_at) or o.finished_at > ^cutoff
  end

  defp live(query) do
    from e in query,
      where: is_nil(e.destroyed_at),
      select: map(e, ^(@environment_fields ++ @observations))
  end

  defp visible(p, id) do
    if Repo.exists?(Access.environments(p, id)), do: :ok, else: {:error, :missing}
  end

  defp find_one(query) do
    case Repo.one(query) do
      nil -> {:error, :missing}
      row -> {:ok, row}
    end
  end

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} when byte_size(id) == 36 -> {:ok, uuid}
      _ -> {:error, :missing}
    end
  end

  defp permit(p, scope), do: if(scope in p.scopes, do: :ok, else: {:error, :forbidden})

  defp collection(conn, params, scope, build) do
    p = conn.assigns.api_principal

    result =
      with :ok <- permit(p, scope) do
        {query, key, render} = build.(p)
        page(query, key, render, p, scope, params)
      end

    respond(conn, result)
  end

  defp page(query, key, render, principal, resource, params) do
    context = PublicCursor.context(principal, resource)

    with {:ok, cursor} <- PublicCursor.decode(context, params["cursor"]) do
      rows = query |> ordered(key, cursor) |> limit(^(@page_size + 1)) |> Repo.all()
      {items, extra} = Enum.split(rows, @page_size)

      next =
        if extra != [] do
          last = List.last(items)
          PublicCursor.encode(context, {Map.fetch!(last, key), last.id})
        end

      {:ok, %{items: Enum.map(items, render), next_cursor: next}}
    end
  end

  defp ordered(query, :id, cursor) do
    query = order_by(query, [row], row.id)
    if cursor, do: where(query, [row], row.id > ^elem(cursor, 1)), else: query
  end

  defp ordered(query, :inserted_at, cursor) do
    query = order_by(query, [row], desc: row.inserted_at, desc: row.id)

    case cursor do
      nil ->
        query

      {time, id} ->
        where(
          query,
          [row],
          fragment(
            "(?, ?) < (?, ?)",
            row.inserted_at,
            row.id,
            type(^time, :utc_datetime_usec),
            type(^id, :binary_id)
          )
        )
    end
  end

  defp ordered(query, key, cursor) do
    query = order_by(query, [row], [field(row, ^key), row.id])

    case cursor do
      nil -> query
      {value, _id} -> where(query, [row], field(row, ^key) > ^value)
    end
  end

  defp environment_json(env, principal) do
    row = Map.take(env, @environment_fields) |> Map.put(:readiness, Readiness.get(env))

    row =
      if env.expiry_at && env.expiry_action,
        do: Map.put(row, :expiry, %{at: env.expiry_at, action: env.expiry_action}),
        else: row

    if "environments:read" in principal.scopes do
      row
      |> optional(:hostname, env.slug, is_binary(env.tailscale_device_id))
      |> optional(:ssh_user, env.remote_user, EnvironmentConnection.account?(env.remote_user))
      |> optional(
        :workspace_folder,
        env.workspace_folder,
        EnvironmentConnection.workspace?(env.workspace_folder)
      )
    else
      row
    end
  end

  defp optional(row, key, value, true), do: Map.put(row, key, value)
  defp optional(row, _key, _value, false), do: row

  defp operation_json(op) do
    row = Map.take(op, [:id, :environment_id, :action, :trigger, :status])

    cond do
      op.timeout_error ->
        Map.merge(row, %{
          status: "failed",
          error: %{code: "operation_timeout", message: op.timeout_error}
        })

      op.error ->
        Map.put(row, :error, %{code: "operation_" <> op.status, message: op.error})

      true ->
        row
    end
  end

  defp respond(conn, {:ok, body}), do: json(conn, body)

  defp respond(conn, {:error, :missing}),
    do: error(conn, 404, "resource_not_found", "Resource not found.")

  defp respond(conn, {:error, :forbidden}),
    do: error(conn, 403, "insufficient_scope", "The connection does not have the required scope.")

  defp respond(conn, {:error, :cursor}),
    do: error(conn, 422, "invalid_request", "Invalid cursor for this collection.")

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{code: code, message: message})
end
