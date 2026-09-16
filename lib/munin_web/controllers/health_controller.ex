defmodule MuninWeb.HealthController do
  use MuninWeb, :controller

  def show(conn, _params), do: json(conn, %{ok: true, service: "munin"})
end
