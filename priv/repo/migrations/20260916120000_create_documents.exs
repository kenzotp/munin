defmodule Munin.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sha256, :text, null: false
      add :path, :text, null: false
      add :filename, :text, null: false
      add :mime, :text
      add :size, :bigint
      add :source, :text, null: false, default: "upload"
      add :title, :text
      add :body_text, :text
      add :read_status, :text, null: false, default: "pending"
      add :meta, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:sha256])
    create index(:documents, [:inserted_at])
  end
end
