defmodule MuninWeb.SubscriptionsLive do
  @moduledoc """
  The subscriptions radar: recurring charges detected from the bank lines —
  monthly and yearly cost, next-charge estimate, price-hike flags. A payee
  can be silenced with one click (an "ignore_sub" rule); un-ignore from the
  Rules section on the transactions page.
  """
  use MuninWeb, :live_view
  import MuninWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok, reload(socket)}
  end

  defp reload(socket) do
    subs = Munin.Money.subscription_detail()

    monthly_total =
      Enum.filter(subs, &(&1.interval == 1)) |> Enum.reduce(0, &(&1.charge_cents + &2))

    yearly_total = Enum.reduce(subs, 0, &(&1.yearly_cents + &2))

    assign(socket,
      page_title: "Subscriptions",
      subs: subs,
      monthly_total: monthly_total,
      yearly_total: yearly_total
    )
  end

  @impl true
  def handle_event("ignore", %{"payee" => payee}, socket) do
    case Munin.Money.create_rule(%{kind: "ignore_sub", pattern: payee}) do
      {:ok, _rule} ->
        {:noreply, socket |> put_flash(:info, "\"#{payee}\" hidden from the radar.") |> reload()}

      {:error, _cs} ->
        {:noreply, socket |> put_flash(:error, "Already ignored.") |> reload()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <div class="flex items-center justify-between mb-2">
        <h1 class="text-2xl font-extrabold">Subscriptions</h1>
        <div class="flex gap-3 text-sm">
          <.link href={~p"/money"} class="m-link">Cockpit</.link>
          <.link href={~p"/money/tx"} class="m-link">Transactions</.link>
        </div>
      </div>
      <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">
        Detected from your bank lines: monthly = 3+ charges in distinct months, yearly = 2 charges ~12 months apart.
      </p>

      <.flash kind={:info} title="" flash={@flash} />

      <div class="grid sm:grid-cols-2 gap-4 mb-8">
        <div class="m-panel">
          <h2 class="m-sec">Recurring per month</h2>
          <p class="text-2xl font-semibold mt-2">{money(@monthly_total)}</p>
          <p class="text-xs text-zinc-400 mt-1">{length(Enum.filter(@subs, &(&1.interval == 1)))} monthly subscriptions</p>
        </div>
        <div class="m-panel">
          <h2 class="m-sec">All recurring, projected year</h2>
          <p class="text-2xl font-semibold mt-2">{money(@yearly_total)}</p>
          <p class="text-xs text-zinc-400 mt-1">{length(@subs)} subscriptions total</p>
        </div>
      </div>

      <%= if @subs == [] do %>
        <p class="text-sm text-zinc-500 py-6 text-center">
          Nothing recurring detected yet — it needs a few months of bank lines.
        </p>
      <% else %>
        <table class="m-table">
          <thead>
            <tr class="text-left">
              <th class="py-2 pr-4">Payee</th><th class="py-2 pr-4 text-right">Charge</th><th class="py-2 pr-4 text-right">Per year</th><th class="py-2 pr-4">Next charge</th><th class="py-2 pr-4">Last seen</th><th class="py-2 pr-4">Flags</th><th class="py-2"></th>
            </tr>
          </thead>
          <tbody>
            <%= for s <- @subs do %>
              <tr class="border-t border-zinc-200 dark:border-zinc-800">
                <td class="py-2 pr-4">
                  <b>{s.payee}</b>
                  <span class="block text-xs text-zinc-400">{s.account} · {s.scope}</span>
                </td>
                <td class="py-2 pr-4 text-right whitespace-nowrap">
                  {money(s.charge_cents)} <span class="text-xs text-zinc-400">{if s.interval == 12, do: "/yr", else: "/mo"}</span>
                </td>
                <td class="py-2 pr-4 text-right whitespace-nowrap text-zinc-500">{money(s.yearly_cents)}</td>
                <td class="py-2 pr-4 whitespace-nowrap">
                  <%= if s.next_charge do %>
                    {MuninWeb.Format.date(s.next_charge)}
                  <% else %>
                    <span class="text-zinc-400">stale</span>
                  <% end %>
                </td>
                <td class="py-2 pr-4 whitespace-nowrap text-zinc-500">{MuninWeb.Format.date(s.last_charge)} <span class="text-xs text-zinc-400">×{s.charges}</span></td>
                <td class="py-2 pr-4">
                  <%= if s.hike do %>
                    <span class="rounded-full bg-red-100 dark:bg-red-950 text-red-700 dark:text-red-300 text-xs font-semibold px-2.5 py-0.5 whitespace-nowrap">
                      price {money(-s.hike.from)} → {money(-s.hike.to)}
                    </span>
                  <% end %>
                  <%= if s.scope == "business" do %>
                    <span class="rounded-full m-chip m-chip-dim text-xs font-medium px-2.5 py-0.5">business</span>
                  <% end %>
                </td>
                <td class="py-2 text-right">
                  <button phx-click="ignore" phx-value-payee={s.payee}
                    class="text-xs font-semibold text-zinc-400 hover:text-red-600" title="Not a subscription — hide from the radar">
                    ignore
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
        <p class="text-xs text-zinc-400 mt-4">
          Ignored payees come back via the Rules section on the Transactions page.
        </p>
      <% end %>
    </div>
    """
  end
end
