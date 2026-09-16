defmodule MuninWeb.UploadController do
  @moduledoc """
  POST /api/upload — the paperless-compatible door. Multipart field `file`.
  201 = stored, 200 = duplicate (sha256 already in the vault), 422 = invalid.
  """
  use MuninWeb, :controller

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    case Munin.Documents.store_upload(upload) do
      {:ok, doc, :new} ->
        %{id: doc.id}
        |> Munin.Workers.ReadWorker.new()
        |> Oban.insert()

        conn
        |> put_status(:created)
        |> json(%{id: doc.id, sha256: doc.sha256, filename: doc.filename, duplicate: false})

      {:ok, doc, :duplicate} ->
        conn
        |> json(%{id: doc.id, sha256: doc.sha256, filename: doc.filename, duplicate: true})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: inspect(changeset.errors)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "multipart field 'file' required"})
  end

  @doc "POST /api/documents/:id/read — re-run the reading ladder (e.g. after a failure)."
  def read(conn, %{"id" => id}) do
    doc = Munin.Documents.get_document!(id)

    %{id: doc.id}
    |> Munin.Workers.ReadWorker.new()
    |> Oban.insert()

    json(conn, %{id: doc.id, queued: true})
  end
end
