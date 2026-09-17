defmodule Munin.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Bank account label (IBAN or "SIMULATED") — P3 wires real accounts here.
      add :account, :string, null: false
      add :external_id, :string
      # Firefly-style content hash: the dedupe wall. Unique per account.
      add :hash, :string, null: false
      add :booked_at, :date, null: false
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false, default: "EUR"
      add :payer, :string
      add :description, :string
      add :iban, :string
      add :category, :string
      add :scope, :string
      # csv | simulated | fints
      add :source, :string, null: false, default: "csv"
      add :matched_document_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create unique_index(:transactions, [:account, :hash])
    create index(:transactions, [:booked_at])
    create index(:transactions, [:matched_document_id])
  end
end
