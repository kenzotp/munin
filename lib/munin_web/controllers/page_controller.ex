defmodule MuninWeb.PageController do
  use MuninWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
