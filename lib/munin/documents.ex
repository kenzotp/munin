defmodule Munin.Documents do
  @moduledoc """
  The vault context: content-addressed storage on the NAS mount plus the
  Postgres metadata rows. SHA-256 is the dedupe key — the same bytes can never
  enter the vault twice, no matter which door they come through.
  """

  import Ecto.Query
  alias Munin.Documents.Document
  alias Munin.Repo

  def vault_path, do: System.get_env("VAULT_PATH", "/vault")

  @doc "Sha256 of a file, streamed — uploads can be large, memory must not be."
  def file_sha256!(path) do
    File.stream!(path, [], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def get_document!(id), do: Repo.get!(Document, id)
  def get_by_sha256(sha), do: Repo.get_by(Document, sha256: sha)

  @doc """
  Store an uploaded temp file into the vault and create its row. Returns
  `{:ok, doc, :new}` or `{:ok, existing, :duplicate}` — the duplicate keeps the
  FIRST copy and tells the caller which door tried to bring it in again.
  """
  def store_upload(%Plug.Upload{} = upload, source \\ "upload") do
    sha = file_sha256!(upload.path)

    case get_by_sha256(sha) do
      %Document{} = existing ->
        {:ok, existing, :duplicate}

      nil ->
        now = DateTime.utc_now()
        dir = Path.join([vault_path(), Integer.to_string(now.year), String.pad_leading(Integer.to_string(now.month), 2, "0")])
        File.mkdir_p!(dir)
        safe_name = sanitize(upload.filename)
        dest = Path.join(dir, "#{sha}__#{safe_name}")
        File.cp!(upload.path, dest)

        %Document{}
        |> Document.changeset(%{
          sha256: sha,
          path: dest,
          filename: upload.filename,
          mime: upload.content_type,
          size: File.stat!(dest).size,
          source: source
        })
        |> Repo.insert()
        |> tap(fn
          {:ok, _doc} -> File.rm(upload.path)
          _ -> :ok
        end)
        |> case do
          {:ok, doc} -> {:ok, doc, :new}
          error -> error
        end
    end
  end

  @doc "List newest first; `q` searches filename, title and the read body text."
  def list_documents(q \\ nil, limit \\ 100) do
    base = from(d in Document, order_by: [desc: d.inserted_at], limit: ^limit)

    query =
      if q in [nil, ""] do
        base
      else
        needle = "%#{q}%"

        from d in base,
          where:
            ilike(d.filename, ^needle) or
              ilike(coalesce(d.title, ""), ^needle) or
              ilike(coalesce(d.body_text, ""), ^needle)
      end

    Repo.all(query)
  end

  @doc """
  The reading ladder, P1 shape: PDFs with an embedded text layer are read
  directly; anything else goes to the vision sidecar page-render + OpenRouter
  VLM OCR (see Munin.Reading). Writes body_text + read_status; the original is
  never touched.
  """
  def read_document!(%Document{} = doc) do
    result = Munin.Reading.read(doc)

    doc
    |> Document.changeset(%{body_text: result.text, read_status: result.status})
    |> Repo.update!()
  rescue
    e ->
      Logger.error("[reading] failed for #{doc.id}: #{Exception.message(e)}")

      doc
      |> Document.changeset(%{read_status: "failed"})
      |> Repo.update!()
  end

  defp sanitize(name) do
    name
    |> String.replace(~r/[^\w.\- ]/, "_")
    |> String.slice(0, 120)
    |> Kernel.||("file")
  end
end
