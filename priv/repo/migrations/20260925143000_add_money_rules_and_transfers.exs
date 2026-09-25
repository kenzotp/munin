defmodule Munin.Repo.Migrations.AddMoneyRulesAndTransfers do
  use Ecto.Migration

  def change do
    # Learned classification rules: a payee/purpose pattern → category + scope.
    # kind "classify" drives the scope/category of matching bank lines,
    # kind "ignore_sub" hides a normalized payee from the subscriptions radar.
    create table(:money_rules, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :string, null: false, default: "classify")
      add(:pattern, :string, null: false)
      add(:category, :string)
      add(:scope, :string)

      timestamps(type: :utc_datetime)
    end

    create(index(:money_rules, [:kind]))
    create(index(:money_rules, [:pattern]))

    alter table(:transactions) do
      add(:is_transfer, :boolean, null: false, default: false)
    end
  end
end
