defmodule MuninWeb.MoneyLive do
  @moduledoc """
  The cockpit: where the money goes, business vs private, what recurs, what's
  missing a receipt. P4-lite, fed by the money core (CSV + simulator today,
  real banks in P3).
  """
  use MuninWeb, :live_view
  alias Munin.Workers.BankSyncWorker

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Money",
       stats: Munin.Money.cockpit(6),
       simulated: Munin.Money.simulated?(),
       sync_status: BankSyncWorker.status_line()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold">Money</h1>
        <div class="flex gap-3 text-sm">
          <.link href={~p"/money/tx"} class="text-blue-600 dark:text-blue-400 hover:underline">Transactions</.link>
          <.link href={~p"/money/import"} class="text-blue-600 dark:text-blue-400 hover:underline">Import</.link>
          <.link href={~p"/tax"} class="text-blue-600 dark:text-blue-400 hover:underline">Tax</.link>
        </div>
      </div>

      <p class="text-xs text-zinc-400 mb-4">{@sync_status}</p>

      <%= if @simulated do %>
        <div class="mb-6 rounded-xl border border-amber-300 bg-amber-50 dark:border-amber-800 dark:bg-amber-950 px-4 py-3 text-sm text-amber-800 dark:text-amber-200">
          Demo mode — some of these numbers come from <b>simulated</b> bank lines. Clear them any time on the Import page.
        </div>
      <% end %>

      <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Cashflow · last 6 months</h2>
      <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-8">
        <%= if @stats.monthly == [] do %>
          <p class="text-zinc-500 dark:text-zinc-400 text-sm">No transactions yet — import a CSV or add the demo data on the Import page.</p>
        <% else %>
          <% max = @stats.monthly |> Enum.flat_map(fn {_y, _m, i, o} -> [i, o] end) |> Enum.max() %>
          <div class="space-y-3">
            <%= for {y, m, income, out} <- @stats.monthly do %>
              <div class="flex items-center gap-3 text-sm">
                <span class="w-16 text-zinc-500">{:io_lib.format("~4..0B-~2..0B", [y, m]) |> IO.iodata_to_binary()}</span>
                <div class="flex-1 space-y-1">
                  <div class="h-2.5 rounded-full bg-zinc-200 dark:bg-zinc-800 overflow-hidden"><div class="h-full rounded-full bg-green-500" style={"width: #{if(max > 0, do: trunc(income / max * 100), else: 0)}%"}></div></div>
                  <div class="h-2.5 rounded-full bg-zinc-200 dark:bg-zinc-800 overflow-hidden"><div class="h-full rounded-full bg-yellow-400" style={"width: #{if(max > 0, do: trunc(out / max * 100), else: 0)}%"}></div></div>
                </div>
                <span class="w-36 text-right text-zinc-500"><span class="text-green-600 dark:text-green-400">+{money(income)}</span> · {money(out)}</span>
              </div>
            <% end %>
            <p class="text-xs text-zinc-400 pt-1">green = in · yellow = out</p>
          </div>
        <% end %>
      </div>

      <div class="grid md:grid-cols-2 gap-6 mb-8">
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5">
          <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Business vs private spend</h2>
          <% total = @stats.biz_spend + @stats.priv_spend %>
          <%= if total > 0 do %>
            <div class="h-4 rounded-full overflow-hidden flex mb-3">
              <div class="bg-blue-500" style={"width: #{trunc(@stats.biz_spend / total * 100)}%"}></div>
              <div class="bg-zinc-400" style={"width: #{trunc(@stats.priv_spend / total * 100)}%"}></div>
            </div>
            <p class="text-sm text-zinc-500"><span class="text-blue-600 dark:text-blue-400 font-semibold">business {money(@stats.biz_spend)}</span> · private {money(@stats.priv_spend)}</p>
          <% else %>
            <p class="text-sm text-zinc-500">—</p>
          <% end %>
        </div>
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5">
          <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Recurring (subscriptions)</h2>
          <%= if @stats.subscriptions == [] do %>
            <p class="text-sm text-zinc-500">None detected yet (needs 3+ months of the same amount).</p>
          <% else %>
            <ul class="space-y-1.5 text-sm">
              <%= for s <- @stats.subscriptions do %>
                <li class="flex justify-between"><span>{s.payer} <span class="text-zinc-400">×{s.months}</span></span><span class="text-zinc-500">{money(-s.cents)}/mo</span></li>
              <% end %>
            </ul>
          <% end %>
        </div>
      </div>

      <div class="grid md:grid-cols-2 gap-6">
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5">
          <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Where it goes (top payees)</h2>
          <%= if @stats.top_payees == [] do %>
            <p class="text-sm text-zinc-500">—</p>
          <% else %>
            <ul class="space-y-1.5 text-sm">
              <%= for {payer, count, sum} <- @stats.top_payees do %>
                <li class="flex justify-between"><span class="truncate mr-2">{payer} <span class="text-zinc-400">×{count}</span></span><span class="text-zinc-500 whitespace-nowrap">{money(sum)}</span></li>
              <% end %>
            </ul>
          <% end %>
        </div>
        <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5">
          <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Missing receipts <span class="chip-like text-zinc-400">(business spend, no document)</span></h2>
          <%= if @stats.missing_receipts == [] do %>
            <p class="text-sm text-zinc-500">Nothing missing — every business euro has paper. 🏆</p>
          <% else %>
            <ul class="space-y-1.5 text-sm">
              <%= for t <- @stats.missing_receipts do %>
                <li class="flex justify-between gap-2"><span class="truncate">{t.payer || t.description}</span><span class="text-zinc-500 whitespace-nowrap">{money(t.amount_cents)}</span></li>
              <% end %>
            </ul>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp money(cents) when cents < 0, do: "-" <> money(-cents)
  defp money(cents) do
    eur = :erlang.float_to_binary(cents / 100, decimals: 2)
    "#{eur} €"
  end
end
