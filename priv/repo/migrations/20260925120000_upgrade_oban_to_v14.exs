defmodule Munin.Repo.Migrations.UpgradeObanToV14 do
  use Ecto.Migration

  # oban 2.24 expects schema v14; the P1 migration created v12.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 12)
end
