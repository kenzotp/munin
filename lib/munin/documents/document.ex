defmodule Munin.Documents.Document do
  @moduledoc """
  One document in the vault. The ORIGINAL file is immutable — `path` points at
  `<VAULT_PATH>/<year>/<month>/<sha256>__<filename>` on the NAS mount; every
  derived artifact (OCR text sidecar, extracted fields) lives in columns here,
  never in the original file (GoBD).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "documents" do
    field :sha256, :string
    field :path, :string
    field :filename, :string
    field :mime, :string
    field :size, :integer
    # upload | mail | hugin | scan
    field :source, :string, default: "upload"
    field :title, :string
    # The reading ladder's output (embedded text, sidecar OCR) — searchable.
    field :body_text, :string
    # pending | done | empty | failed
    field :read_status, :string, default: "pending"
    # Free-form extraction result (doc type, vendor, amounts...) — structured
    # columns come with the P2 understanding work; jsonb keeps P1 honest.
    field :meta, :map, default: %{}

    timestamps()
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:sha256, :path, :filename, :mime, :size, :source, :title, :body_text, :read_status, :meta])
    |> validate_required([:sha256, :path, :filename])
    |> unique_constraint(:sha256)
  end
end
