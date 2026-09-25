defmodule MuninWeb.TransactionsLive do
  @moduledoc """
  The bank lines: filterable list + the matching queue. Unmatched invoice
  documents show their ranked candidate lines; one click confirms and locks
  the pair. Auto-matches (exact amount + vendor token hit) are marked.

  Wave 1 (mockup): inline scope toggle + category edit per line, one-click
  learned rules (payee → category/scope, replayed over all lines), internal
  transfer marking (same amount, opposite sign, ±4 days across accounts) and
  German number/date formats.
  """
  use MuninWeb, :live_view
  import MuninWeb.Format

  @categories ~w(income saas fees hardware insurance rent groceries transport health subscriptions dining other)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Transactions", q: "", scope: "all", account: "all") |> reload()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       q: String.trim(params["q"] || ""),
       scope: params["scope"] || "all",
       account: params["account"] || "all"
     )
     |> reload()}
  end

  defp reload(%{assigns: %{q: q, scope: scope, account: account}} = socket) do
    lines = q |> Munin.Money.list_transactions(scope, account, 300) |> Munin.Repo.all()

    queue =
      Munin.Money.unmatched_docs()
      |> Enum.map(fn doc -> {doc, Munin.Money.candidates_for(doc)} end)
      |> Enum.reject(fn {_doc, cands} -> cands == [] end)

    auto = Enum.count(queue, fn {_doc, cands} -> elem(hd(cands), 1) >= 1 end)
    transfer_pairs = Munin.Money.transfer_candidates()

    socket
    |> assign(
      categories: @categories,
      queue: queue,
      auto: auto,
      total: Munin.Repo.aggregate(Munin.Money.Transaction, :count, :id),
      accounts: Munin.Money.accounts(),
      rules: Munin.Money.list_rules(),
      transfer_pairs: transfer_pairs,
      transfer_pairs_shown: Enum.take(transfer_pairs, 6)
    )
    |> stream(:lines, lines, reset: true)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/money/tx?#{%{q: String.trim(q), scope: socket.assigns.scope, account: socket.assigns.account}}"
     )}
  end

  def handle_event("scope", %{"scope" => scope}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/money/tx?#{%{q: socket.assigns.q, scope: scope, account: socket.assigns.account}}"
     )}
  end

  def handle_event("account", %{"account" => account}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/money/tx?#{%{q: socket.assigns.q, scope: socket.assigns.scope, account: account}}"
     )}
  end

  def handle_event("set_scope_line", %{"id" => id}, socket) do
    t = Munin.Repo.get!(Munin.Money.Transaction, id)
    new_scope = if t.scope == "business", do: "private", else: "business"
    Munin.Repo.update!(Ecto.Changeset.change(t, scope: new_scope))
    {:noreply, reload(socket)}
  end

  def handle_event("set_category", %{"_id" => id, "category" => category}, socket) do
    t = Munin.Repo.get!(Munin.Money.Transaction, id)
    Munin.Repo.update!(Ecto.Changeset.change(t, category: category))
    {:noreply, reload(socket)}
  end

  def handle_event("make_rule", %{"id" => id}, socket) do
    t = Munin.Repo.get!(Munin.Money.Transaction, id)

    case Munin.Money.rule_from_line(t) do
      {:ok, rule} ->
        n = Munin.Money.apply_rules!()

        {:noreply,
         socket
         |> put_flash(:info, "Rule \"#{rule.pattern} → #{rule.scope}/#{rule.category}\" — #{n} line(s) re-classified.")
         |> reload()}

      {:error, _cs} ->
        {:noreply, socket |> put_flash(:error, "Rule not saved.") |> reload()}
    end
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    Munin.Money.delete_rule!(id)
    {:noreply, socket |> put_flash(:info, "Rule deleted.") |> reload()}
  end

  def handle_event("apply_rules", _, socket) do
    n = Munin.Money.apply_rules!()
    {:noreply, socket |> put_flash(:info, "Rules applied to #{n} line(s).") |> reload()}
  end

  def handle_event("mark_transfer", %{"out" => out, "in" => inn}, socket) do
    Munin.Money.mark_transfer!(out, inn)
    {:noreply, socket |> put_flash(:info, "Marked as internal transfer.") |> reload()}
  end

  def handle_event("mark_all_transfers", _, socket) do
    pairs = Munin.Money.transfer_candidates()
    Enum.each(pairs, fn {out, inn} -> Munin.Money.mark_transfer!(out.id, inn.id) end)
    {:noreply, socket |> put_flash(:info, "Marked #{length(pairs)} transfer pair(s).") |> reload()}
  end

  def handle_event("toggle_transfer", %{"id" => id}, socket) do
    t = Munin.Repo.get!(Munin.Money.Transaction, id)

    if t.is_transfer do
      Munin.Money.unmark_transfer!(id)
      {:noreply, socket |> put_flash(:info, "Line back in the sums.") |> reload()}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Use the transfer suggestions at the top — both sides get marked.")
       |> reload()}
    end
  end

  def handle_event("confirm", %{"doc" => doc_id, "line" => line_id}, socket) do
    doc = Munin.Repo.get!(Munin.Documents.Document, doc_id)
    line = Munin.Repo.get!(Munin.Money.Transaction, line_id)
    Munin.Money.confirm!(doc, line)
    {:noreply, socket |> put_flash(:info, "Matched: #{doc.title || doc.filename}") |> reload()}
  end

  def handle_event("automatch", _, socket) do
    n = Munin.Money.auto_match_all!()
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
          <.link href={~p"/money/subs"} class="text-blue-600 dark:text-blue-400 hover:underline">Subscriptions</.link>
          <.link href={~p"/money/import"} class="text-blue-600 dark:text-blue-400 hover:underline">Import</.link>
        </div>
      </div>

      <.flash kind={:info} title="" flash={@flash} />

      <div :if={@transfer_pairs != []} class="rounded-xl border border-blue-200 dark:border-blue-900 bg-blue-50 dark:bg-blue-950 p-5 mb-6">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500">
            Internal transfers <span class="chip-like">{length(@transfer_pairs)} pair(s) counted as income + spend</span>
          </h2>
          <button phx-click="mark_all_transfers" class="rounded-lg bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold px-3 py-1.5">
            Mark all {length(@transfer_pairs)} as transfers
          </button>
        </div>
        <ul class="space-y-1 text-sm">
          <li :for={{out, inn} <- @transfer_pairs_shown} class="flex items-center gap-2">
            <span class="text-zinc-500">{MuninWeb.Format.date(out.booked_at)}</span>
            <span class="text-zinc-400">{out.account} → {inn.account}</span>
            <span class="font-medium whitespace-nowrap">{money(out.amount_cents)}</span>
            <button phx-click="mark_transfer" phx-value-out={out.id} phx-value-in={inn.id} class="ml-auto rounded-lg bg-zinc-900 hover:bg-zinc-700 dark:bg-zinc-100 dark:hover:bg-zinc-300 text-white dark:text-zinc-900 text-xs font-semibold px-2.5 py-1">Transfer</button>
          </li>
        </ul>
        <p class="text-xs text-zinc-400 mt-2">Transfers leave the spend and income sums on the cockpit and the EÜR.</p>
      </div>

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
                      <span class="text-zinc-500">{MuninWeb.Format.date(line.booked_at)}</span>
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

      <details class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-4" open={@rules != []}>
        <summary class="cursor-pointer text-xs font-bold uppercase tracking-wider text-zinc-500">
          Rules <span class="chip-like">{length(@rules)} learned — payee → category + scope</span>
        </summary>
        <%= if @rules == [] do %>
          <p class="text-sm text-zinc-500 mt-3">No rules yet. Edit any line below, then press <b>→ rule</b> to apply that payee's classification everywhere, forever.</p>
        <% else %>
          <div class="mt-3 flex flex-wrap gap-2 items-center">
            <%= for r <- @rules do %>
              <span class="inline-flex items-center gap-2 rounded-full bg-zinc-100 dark:bg-zinc-800 px-3 py-1 text-xs">
                <b>{r.pattern}</b> <span class="text-zinc-400">→</span> {r.scope}/{r.category || "—"}
                <button phx-click="delete_rule" phx-value-id={r.id} class="text-zinc-400 hover:text-red-600" title="Delete rule">×</button>
              </span>
            <% end %>
            <button phx-click="apply_rules" class="rounded-lg bg-zinc-900 hover:bg-zinc-700 dark:bg-zinc-100 dark:hover:bg-zinc-300 text-white dark:text-zinc-900 text-xs font-semibold px-3 py-1.5">Re-apply to all lines</button>
          </div>
        <% end %>
      </details>

      <form phx-change="search" class="flex gap-2 items-center mb-4 flex-wrap">
        <input type="search" name="q" value={@q} placeholder="Search payer / purpose…" class="flex-1 min-w-48 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent px-3 py-2 text-sm" />
        <div class="flex gap-1">
          <%= for s <- ["all", "business", "private"] do %>
            <button type="button" phx-click="scope" phx-value-scope={s}
              class={"rounded-full px-3 py-1 text-xs font-medium " <> if @scope == s, do: "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900", else: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"}>
              {s}
            </button>
          <% end %>
        </div>
        <select name="account" class="rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent px-2 py-2 text-sm">
          <option value="all" selected={@account == "all"}>All accounts</option>
          <%= for {acc, count, _latest} <- @accounts do %>
            <option value={acc} selected={@account == acc}>{acc} ({count})</option>
          <% end %>
        </select>
      </form>

      <div id="tx-lines" phx-update="stream">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th class="py-2 pr-4">Date</th><th class="py-2 pr-4">Payer / purpose</th><th class="py-2 pr-4">Category</th><th class="py-2 pr-4">G/P</th><th class="py-2 pr-4">Receipt</th><th class="py-2 pr-4"></th><th class="py-2 text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{id, t} <- @streams.lines} id={id} class="border-t border-zinc-200 dark:border-zinc-800">
              <td class="py-2 pr-4 whitespace-nowrap text-zinc-500">{MuninWeb.Format.date(t.booked_at)}</td>
              <td class="py-2 pr-4">
                {t.payer || "—"} <span class="text-zinc-400">· {t.description}</span>
                <span class="block text-xs text-zinc-400">{t.account}</span>
              </td>
              <td class="py-2 pr-4">
                <form phx-change="set_category" id={"cat-#{t.id}"}>
                  <input type="hidden" name="_id" value={t.id} />
                  <select name="category" class="rounded-lg border border-zinc-200 dark:border-zinc-700 bg-transparent px-1.5 py-1 text-xs">
                    <option value={t.category} selected>{t.category}</option>
                    <%= for c <- @categories -- [t.category] do %>
                      <option value={c}>{c}</option>
                    <% end %>
                  </select>
                </form>
              </td>
              <td class="py-2 pr-4">
                <button phx-click="set_scope_line" phx-value-id={t.id}
                  class={"rounded-full px-2.5 py-0.5 text-xs font-semibold " <> if t.scope == "business", do: "bg-yellow-400 text-yellow-950", else: "bg-zinc-200 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"}>
                  {if t.scope == "business", do: "G", else: "P"}
                </button>
              </td>
              <td class="py-2 pr-4">
                <%= cond do %>
                  <% t.matched_document_id -> %>
                    <span class="text-green-600 dark:text-green-400 text-xs font-medium">✓ receipt</span>
                  <% t.scope == "business" -> %>
                    <span class="text-red-600 dark:text-red-400 text-xs font-medium">missing</span>
                  <% true -> %>
                    <span class="text-zinc-400 text-xs">—</span>
                <% end %>
              </td>
              <td class="py-2 pr-4 whitespace-nowrap">
                <button phx-click="toggle_transfer" phx-value-id={t.id} title={if t.is_transfer, do: "Back in the sums", else: "Internal transfer?"}
                  class={"text-xs font-semibold px-1.5 py-0.5 rounded " <> if t.is_transfer, do: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300", else: "text-zinc-300 dark:text-zinc-600 hover:text-zinc-500"}>
                  ⇄
                </button>
                <button phx-click="make_rule" phx-value-id={t.id} title="Learn: this payee → this category + scope"
                  class="text-xs font-semibold text-zinc-400 hover:text-blue-600 px-1">→ rule</button>
              </td>
              <td class={"py-2 text-right whitespace-nowrap " <> if t.amount_cents < 0, do: "", else: "text-green-600 dark:text-green-400"}>{money(t.amount_cents)}</td>
            </tr>
          </tbody>
        </table>
        <div class="hidden only:block text-sm text-zinc-500 py-6 text-center">No lines — import a bank CSV or add demo data.</div>
      </div>
    </div>
    """
  end
end
