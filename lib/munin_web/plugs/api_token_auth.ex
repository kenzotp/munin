defmodule MuninWeb.Plugs.ApiTokenAuth do
  @moduledoc """
  Bearer-token auth for the machine doors (/api/*). The token is the
  instance's UPLOAD_TOKEN env — same secret for Hugin, the phone PWA and any
  paperless-compatible uploader. Constant-time compare, 401 JSON on failure.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = System.get_env("UPLOAD_TOKEN", "")
    provided = get_req_header(conn, "authorization") |> List.first()

    if is_binary(provided) and is_binary(expected) and expected != "" do
      token = String.replace_prefix(provided, "Bearer ", "")

      if Plug.Crypto.secure_compare(token, expected) do
        conn
      else
        deny(conn)
      end
    else
      deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
