defmodule Munin.Repo.Migrations.CreateBankSyncs do
  use Ecto.Migration

  def change do
    create table(:bank_syncs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # When the attempt happened (UTC) and what triggered it — the daily
      # Oban cron job, or the "Fetch statements" button on /money/import.
      add :attempted_at, :utc_datetime, null: false
      add :trigger, :string, null: false

      # "ok" carries imported/duplicates; "error" carries error_message
      # (Fints.fetch/2's human-readable reason, e.g. a latch or sidecar
      # error) — never both.
      add :status, :string, null: false
      add :imported, :integer
      add :duplicates, :integer
      add :error_message, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:bank_syncs, [:attempted_at])
  end
end
