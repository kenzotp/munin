defmodule MuninWeb.ImportLive do
  @moduledoc """
  Feed the money core without banks: paste a bank CSV (real Sparkasse exports
  work as-is) or pull in 8 months of simulated lines to explore the cockpit.
  """
  use MuninWeb, :live_view
  alias Munin.Money
  alias Munin.Money.Fints
  alias Munin.Workers.BankSyncWorker

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Import",
       csv: "",
       account: "Sparkasse",
       result: nil,
       simulated: Money.simulated?(),
       fints_configured: Fints.configured?(),
       fints_missing: Fints.missing_keys(),
       fints_days: "90",
       fints_busy: false,
       fints_latch: fints_latch(),
       sync_status: BankSyncWorker.status_line()
     )}
  end

  defp fints_latch do
    if Fints.configured?(), do: Fints.latch_status(), else: :clear
  end

  @impl true
  def handle_event("save", %{"csv" => csv, "account" => account}, socket) do
    {rows, errors} = Money.parse_csv(csv)
    {imported, dups} =
      if rows == [] do
        {0, 0}
      else
        Money.import_rows(String.trim(account) <> "", rows, "csv")
      end

    {:noreply,
     socket
     |> assign(result: {imported, dups, length(errors)}, csv: csv)
     |> put_flash(
       :info,
       "#{imported} imported, #{dups} duplicates skipped, #{length(errors)} unparseable rows."
     )
     |> reload_flag()}
  end

  def handle_event("simulate", _, socket) do
    {imported, dups} = Money.seed_demo!()
    Money.auto_match_all!()

    {:noreply,
     socket
     |> assign(simulated: true)
     |> put_flash(:info, "Demo data: #{imported} lines imported (#{dups} dup), 2 demo invoices queued + auto-matched.")}
  end

  def handle_event("clear_simulated", _, socket) do
    n = Money.delete_simulated!()
    {:noreply, socket |> assign(simulated: false) |> put_flash(:info, "Deleted #{n} simulated lines (and re-checked matches are gone with them).")}
  end

  def handle_event("fints", %{"days" => days}, socket) do
    if socket.assigns.fints_busy do
      # A fetch is already in flight in this LiveView; ignore the extra click.
      {:noreply, socket}
    else
      days =
        case Integer.parse(days) do
          {n, ""} when n in 1..720 -> n
          _ -> 90
        end

      start_date = Date.add(Date.utc_today(), -days)

      {:noreply,
       socket
       |> assign(fints_busy: true)
       |> start_async(:fints_fetch, fn -> Fints.fetch(start_date) end)}
    end
  end

  def handle_event("fints_reset_state", _, socket) do
    Fints.reset_state!()

    {:noreply,
     socket
     |> put_flash(:info, "Bank session reset — the next fetch starts fresh.")}
  end

  def handle_event("fints_clear_latch", _, socket) do
    Fints.clear_latch!()

    {:noreply,
     socket
     |> assign(fints_latch: :clear)
     |> put_flash(:info, "Latch cleared — one fetch attempt is allowed.")}
  end

  @impl true
  def handle_async(:fints_fetch, {:ok, {:ok, result} = fetch_result}, socket) do
    Fints.record_sync!(:manual, fetch_result)

    {:noreply,
     socket
     |> assign(fints_busy: false, fints_latch: fints_latch(), sync_status: BankSyncWorker.status_line())
     |> put_flash(:info, fints_flash_message(result))}
  end

  def handle_async(:fints_fetch, {:ok, {:error, reason} = fetch_result}, socket) do
    Fints.record_sync!(:manual, fetch_result)

    {:noreply,
     socket
     |> assign(fints_busy: false, fints_latch: fints_latch(), sync_status: BankSyncWorker.status_line())
     |> put_flash(:error, "FinTS: " <> reason)}
  end

  def handle_async(:fints_fetch, {:exit, reason}, socket) do
    Fints.record_sync!(:manual, {:error, "fetch crashed (#{inspect(reason)})"})

    {:noreply,
     socket
     |> assign(fints_busy: false, fints_latch: fints_latch(), sync_status: BankSyncWorker.status_line())
     |> put_flash(:error, "FinTS: fetch crashed (#{inspect(reason)}).")}
  end

  defp fints_flash_message(%{imported: imported, duplicates: dups, accounts: accounts}) do
    suffix =
      case accounts do
        [_ | _] = accounts -> " across #{length(accounts)} account(s)."
        [] -> "."
      end

    "FinTS: #{imported} lines imported, #{dups} duplicates skipped" <> suffix
  end

  defp reload_flag(socket), do: assign(socket, simulated: Money.simulated?())

  defp fints_latch_reason_label("locked"), do: "the bank locked online banking"
  defp fints_latch_reason_label(_), do: "the bank rejected the PIN or login"

  defp fints_latch_age(%DateTime{} = at),
    do: " at " <> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp fints_latch_age(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-8">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold">Import</h1>
        <div class="flex gap-3 text-sm">
          <.link href={~p"/money"} class="text-blue-600 dark:text-blue-400 hover:underline">Cockpit</.link>
          <.link href={~p"/money/tx"} class="text-blue-600 dark:text-blue-400 hover:underline">Transactions</.link>
        </div>
      </div>

      <.flash kind={:info} title="" flash={@flash} />
      <.flash kind={:error} title="" flash={@flash} />

      <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-6">
        <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Bank sync · FinTS</h2>
        <p class="text-xs text-zinc-400 mb-3">{@sync_status}</p>
        <%= if @fints_configured do %>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-3">
            Read-only statement fetch from your bank (Sparkasse). Approval happens in your banking app (S-pushTAN) — no TAN is ever typed here.
          </p>
          <%= if @fints_busy do %>
            <p class="text-sm text-blue-600 dark:text-blue-400 mb-3">
              Waiting for approval — open the S-pushTAN app and approve the push now.
            </p>
          <% end %>
          <%= if match?({:latched, _, _}, @fints_latch) do %>
            <% {:latched, reason, at} = @fints_latch %>
            <div class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/40 p-3 mb-3 text-sm text-red-700 dark:text-red-300">
              <p class="font-semibold mb-1">Bank fetch blocked — <%= fints_latch_reason_label(reason) %></p>
              <p class="mb-2">
                Latched<%= fints_latch_age(at) %>. Check FINTS_LOGIN/FINTS_PIN in the banking app before retrying — Sparkasse locks online banking after 3 wrong PINs.
              </p>
              <button phx-click="fints_clear_latch"
                class="rounded-lg border border-red-400 dark:border-red-700 px-3 py-1.5 text-sm hover:bg-red-100 dark:hover:bg-red-900/40">
                I checked the PIN in the banking app — allow one attempt
              </button>
            </div>
          <% end %>
          <form phx-submit="fints" class="flex items-center gap-2">
            <input type="number" name="days" min="1" max="720" value={@fints_days} disabled={@fints_busy}
              class="w-24 rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent px-3 py-2 text-sm" />
            <span class="text-sm text-zinc-500">days back</span>
            <button type="submit" disabled={@fints_busy or match?({:latched, _, _}, @fints_latch)}
              class="rounded-lg bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white font-semibold px-4 py-2 text-sm">
              <%= if @fints_busy, do: "Waiting for approval…", else: "Fetch statements" %>
            </button>
          </form>
          <button phx-click="fints_reset_state"
            class="mt-2 text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 underline">
            Reset bank session
          </button>
        <% else %>
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            Waiting for credentials. Set <code class="text-zinc-400"><%= Enum.join(@fints_missing, ", ") %></code> in .env
            (the DK product ID is already there) and rebuild. Get your own free registration at fints.org — never ship one in the repo.
          </p>
        <% end %>
      </div>

      <div class="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5 mb-6">
        <h2 class="text-xs font-bold uppercase tracking-wider text-zinc-500 mb-3">Demo data</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-3">
          8 months of plausible business + private lines, plus two demo invoices so the matching queue has something to show. Marked <b>simulated</b> — removable.
        </p>
        <%= if @simulated do %>
          <button phx-click="clear_simulated" class="rounded-lg border border-zinc-300 dark:border-zinc-700 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:hover:bg-zinc-800">Delete simulated lines</button>
        <% else %>
          <button phx-click="simulate" class="rounded-lg bg-yellow-400 hover:bg-yellow-300 text-yellow-950 font-semibold px-4 py-1.5 text-sm">Add demo data</button>
        <% end %>
      </div>

      <form phx-submit="save" class="space-y-4">
        <label class="block text-sm">
          <span class="text-xs font-bold uppercase tracking-wider text-zinc-500">Account label</span>
          <input type="text" name="account" value={@account}
            class="mt-1 w-full rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent px-3 py-2 text-sm" />
        </label>
        <label class="block text-sm">
          <span class="text-xs font-bold uppercase tracking-wider text-zinc-500">Paste bank CSV</span>
          <textarea name="csv" rows="12" phx-debounce="250"
            class="mt-1 w-full rounded-lg border border-zinc-300 dark:border-zinc-700 bg-transparent px-3 py-2 text-sm font-mono"
            placeholder={"Buchungstag;Wertstellung;Vorgang;Buchungstext;Zahlungspflichtige(r);IBAN;Betrag\n01.09.2026;01.09.2026;Lastschrift;OpenRouter AI API;OPENROUTER;DE89...;-12,34"}><%= @csv %></textarea>
          <span class="text-xs text-zinc-400">Sparkasse / generic German exports parse as-is — semicolons, commas or tabs.</span>
        </label>
        <button type="submit" class="rounded-lg bg-blue-600 hover:bg-blue-500 text-white font-semibold px-4 py-2 text-sm">Import CSV</button>
      </form>
    </div>
    """
  end
end
