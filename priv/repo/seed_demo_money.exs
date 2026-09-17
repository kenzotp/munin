# Seeds the money core with simulated data (run inside the app container):
#   docker cp priv/repo/seed_demo_money.exs munin-munin_web-1:/tmp/seed.exs
#   docker exec munin-munin_web-1 /app/bin/munin eval 'Code.require_file("/tmp/seed.exs")'
# Run in a THROWAWAY release container on the munin network (PHX_SERVER=false
# so the endpoint takes no port); the full app must start — Repo alone misses
# the DBConnection watcher.
{:ok, _} = Application.ensure_all_started(:munin)

case Munin.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

cleared = Munin.Money.delete_simulated!()
IO.puts("cleared #{cleared} previous simulated lines")

import Ecto.Query
{del_docs, _} = Munin.Repo.delete_all(from d in Munin.Documents.Document, where: d.source == "simulated")
IO.puts("cleared #{del_docs} previous demo documents")

{imported, dups} = Munin.Money.seed_demo!()
IO.puts("seeded: #{imported} lines (#{dups} duplicates skipped)")

n = Munin.Money.auto_match_all!()
IO.puts("auto-matched #{n} demo invoices")

stats = Munin.Money.cockpit(6)
IO.puts("months: #{length(stats.monthly)}, subscriptions: #{length(stats.subscriptions)}, missing receipts: #{length(stats.missing_receipts)}")

year = Munin.Money.latest_year()
eur = Munin.Money.eur(year)
IO.puts("#{year}: revenue #{:erlang.float_to_binary(eur.revenue / 100, decimals: 2)} EUR, profit #{:erlang.float_to_binary(eur.profit / 100, decimals: 2)} EUR, USt estimate #{:erlang.float_to_binary((eur.output_vat - eur.input_vat) / 100, decimals: 2)} EUR")
