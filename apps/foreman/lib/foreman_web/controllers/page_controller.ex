defmodule ForemanWeb.PageController do
  use ForemanWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
