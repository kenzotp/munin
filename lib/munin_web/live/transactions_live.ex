defmodule MuninWeb.TransactionsLive do
  @moduledoc """
  The bank lines: filterable list + the matching queue. Unmatched invoice
  documents show their ranked candidate lines; one click confirms and locks
  the pair. Auto-matches (exact amount + vendor token hit) are marked.
  """
  use MuninWeb, :live_view
  alias Munin.Money

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Transactions", q: "", scope: "all") |> reload()}
  end

  @impl true
  def handle_params(%{"q" => q} = params, _uri, socket) do
    {:noreply, assign(socket, q: String.trim(q || ""), scope: params["scope"] || "all") |> reload()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp reload(%{assigns: %{q: q, scope: scope}} = socket) do
    lines = Munin.Money.list_transactions(q, scope, 300)
    queue =
      Money.unmatched_docs()
      |> Enum.map(fn doc -> {doc, Money.candidates_for(doc)} end)
      |> Enum.reject(fn {_doc, cands} -> cands == [] end)

    auto = Enum.count(queue, fn {_doc, cands} -> elem(hd(cands), 1) >= 1 end)

    assign(socket,
      lines: lines,
      queue: queue,
      auto: auto,
      total: Munin.Repo.aggregate(Munin.Money.Transaction, :count, :id)
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/money/tx?#{%{q: String.trim(q), scope: socket.assigns.scope}}")}
  end

  def handle_event("scope", %{"scope" => scope}, socket) do
    {:noreply, push_patch(socket, to: ~p"/money/tx?#{%{q: socket.assigns.q, scope: scope}}")}
  end

  def handle_event("confirm", %{"doc" => doc_id, "line" => line_id}, socket) do
    doc = Munin.Repo.get!(Munin.Documents.Document, doc_id)
    line = Munin.Repo.get!(Money.Transaction, line_id)
    Money.confirm!(doc, line)
    {:noreply, socket |> put_flash(:info, "Matched: #{doc.title || doc.filename}") |> reload()}
  end

  def handle_event("automatch", _, socket) do
    n = Money.auto_match_all!()
    {:noreply, socket |> put_flash(:info, "Auto-matched #{n} document(s).") |> reload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl px-4 py-8">
      <div class="flex items-center justify-between mb-2">
        <h1 class="text-2xl font-semibold">Transactions <span class="text-zinc-400 text-base">{@total}</span></h1>
        <div class="flex gap-3 text-sm">
          <.link href={~p"/money"} class="text-blue-600 dark:text-blue-400 hover:underline">Cockpit</.link>
          <.link href={~p"/money/import"} class="text-blue-600 dark:text-blue-400 hover:underline">Import</.link>
        </div>
      </div>

      <.flash kind={:info} title="" flash={@flash} />

      <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-8">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500">Matching queue <span class="chip-like">{length(@queue)} waiting · {@auto} auto-candidates</span></h2>
          <button phx-click="automatch" class="rounded-lg bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold px-3 py-1.5">Auto-match all</button>
        </div>
        <%= if @queue == [] do %>
          <p class="text-sm text-zinc-500">No invoices waiting for a bank line. Upload invoices (or let the pipeline read them) and matching happens here.</p>
        <% else %>
          <div class="space-y-4">
            <%= for {doc, cands} <- @queue do %>
              <div class="rounded-lg border border-zinc-200 dark:border-zinc-800 p-3">
                <div class="flex items-center justify-between mb-2">
                  <div>
                    <b class="text-sm"><.link navigate={~p"/documents/#{doc.id}"} class="hover:underline">{doc.title || doc.filename}</.link></b>
                    <span class="text-zinc-500 text-sm ml-2">
                      {doc.meta["vendor"]} · {money(round((doc.meta["invoice"]["total_gross"] || 0) * 100))} · {doc.meta["invoice"]["date"]}
                    </span>
                  </div>
                  <span class="text-xs text-zinc-400">{doc.meta["scope"]}</span>
                </div>
                <ul class="space-y-1">
                  <%= for {line, score} <- cands do %>
                    <li class="flex items-center gap-2 text-sm">
                      <span class={"rounded px-1.5 py-0.5 text-xs font-bold " <> if score >= 1, do: "bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300", else: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"}>score {score}</span>
                      <span class="text-zinc-500">{Date.to_iso8601(line.booked_at)}</span>
                      <span class="truncate flex-1">{line.payer} — <span class="text-zinc-400">{line.description}</span></span>
                      <span class="whitespace-nowrap">{money(line.amount_cents)}</span>
                      <button phx-click="confirm" phx-value-doc={doc.id} phx-value-line={line.id} class="rounded-lg bg-zinc-900 hover:bg-zinc-700 dark:bg-zinc-100 dark:hover:bg-zinc-300 text-white dark:text-zinc-900 text-xs font-semibold px-2.5 py-1">Confirm</button>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <form phx-change="search" class="flex gap-2 items-center mb-4">
        <input type="search" name="q" value={@q} placeholder="Search payer / purpose…" class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent px-3 py-2 text-sm" />
        <div class="flex gap-1">
          <%= for s <- ["all", "business", "private"] do %>
            <button type="button" phx-click="scope" phx-value-scope={s}
              class={"rounded-full px-3 py-1 text-xs font-medium " <> if @scope == s, do: "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900", else: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"}>
              {s}
            </button>
          <% end %>
        </div>
      </form>

      <table class="w-full text-sm">
        <thead>
          <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
            <th class="py-2 pr-4">Date</th><th class="py-2 pr-4">Payer / purpose</th><th class="py-2 pr-4">Category</th><th class="py-2 pr-4">Scope</th><th class="py-2 pr-4">Document</th><th class="py-2 text-right">Amount</th>
          </tr>
        </thead>
        <tbody>
          <%= for t <- @lines do %>
            <tr class="border-t border-zinc-200 dark:border-zinc-800">
              <td class="py-2 pr-4 whitespace-nowrap text-zinc-500">{Date.to_iso8601(t.booked_at)}</td>
              <td class="py-2 pr-4">{t.payer || "—"} <span class="text-zinc-400">· {t.description}</span></td>
              <td class="py-2 pr-4 text-zinc-500">{t.category}</td>
              <td class="py-2 pr-4">{t.scope}</td>
              <td class="py-2 pr-4"><%= if t.matched_document_id do %><span class="text-green-600 dark:text-green-400">✓ matched</span><% else %><span class="text-zinc-400">—</span><% end %></td>
              <td class={"py-2 text-right whitespace-nowrap " <> if t.amount_cents < 0, do: "", else: "text-green-600 dark:text-green-400"}>{money(t.amount_cents)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <%= if @lines == [] do %>
        <p class="text-sm text-zinc-500 py-6 text-center">No lines — import a bank CSV or add demo data.</p>
      <% end %>
    </div>
    """
  end

  defp money(cents) when cents < 0, do: "-" <> money(-cents)
  defp money(cents), do: "#{:erlang.float_to_binary(cents / 100, decimals: 2)} €"
end
