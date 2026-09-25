defmodule MuninWeb.TaxLive do
  @moduledoc """
  P5-lite, honest about being an estimate: EÜR-style sums over *classified
  business* bank lines, and a rough USt worksheet (19% output assumed, input
  VAT from matched invoices). The Steuerberater still gets DATEV exports
  later; this is the always-on picture.
  """
  use MuninWeb, :live_view
  import MuninWeb.Format
  alias Munin.Money

  @impl true
  def mount(params, _session, socket) do
    year =
      case Integer.parse(params["year"] || "") do
        {n, ""} when n in 2000..2100 -> n
        _ -> Money.latest_year()
      end

    {:ok, assign(socket, page_title: "Tax", year: year, eur: Money.eur(year))}
  end

  @impl true
  def handle_params(%{"year" => y}, _uri, socket) when is_binary(y) do
    case Integer.parse(y) do
      {n, ""} -> {:noreply, assign(socket, year: n, eur: Money.eur(n))}
      _ -> {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-8">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold">Tax <span class="text-zinc-400 text-base">{@year}</span></h1>
        <div class="flex gap-3 text-sm">
          <%= for y <- [@year - 1, @year, @year + 1] do %>
            <.link href={~p"/tax?#{%{year: y}}"} class={if y == @year, do: "font-bold text-blue-600 dark:text-blue-400", else: "text-zinc-500 hover:underline"}>{y}</.link>
          <% end %>
        </div>
      </div>

      <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-6">
        <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">EÜR picture (business lines, classified)</h2>
        <table class="w-full text-sm mb-2">
          <tbody>
            <tr><td class="py-1">Revenue</td><td class="py-1 text-right font-semibold">{money(@eur.revenue)}</td></tr>
            <%= for {cat, cents} <- @eur.by_cat do %>
              <tr class="border-t border-zinc-100 dark:border-zinc-900">
                <td class="py-1 text-zinc-500">{cat}</td><td class="py-1 text-right">{money(cents)}</td>
              </tr>
            <% end %>
            <tr class="border-t border-zinc-200 dark:border-zinc-800"><td class="py-1 font-semibold">Expenses</td><td class="py-1 text-right font-semibold">{money(-@eur.expenses)}</td></tr>
            <tr class="border-t-2 border-zinc-300 dark:border-zinc-700"><td class="py-1 font-bold">Profit</td><td class="py-1 text-right font-bold">{money(@eur.profit)}</td></tr>
          </tbody>
        </table>
      </div>

      <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-6">
        <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">USt estimate worksheet</h2>
        <table class="w-full text-sm">
          <tbody>
            <tr><td class="py-1">Output VAT (19% assumed on revenue)</td><td class="py-1 text-right">{money(@eur.output_vat)}</td></tr>
            <tr><td class="py-1 text-zinc-500">Input VAT (from matched invoices)</td><td class="py-1 text-right text-zinc-500">− {money(@eur.input_vat)}</td></tr>
            <tr class="border-t border-zinc-200 dark:border-zinc-800"><td class="py-1 font-semibold">Balance (estimate)</td><td class="py-1 text-right font-semibold">{money(@eur.output_vat - @eur.input_vat)}</td></tr>
          </tbody>
        </table>
      </div>

      <p class="text-xs text-zinc-400">
        Estimates built from classified bank lines — not a filing. Real USt depends on invoice dates, Kleinunternehmer rules and cash vs accrual; the DATEV export lands with P5.
      </p>
    </div>
    """
  end
end
