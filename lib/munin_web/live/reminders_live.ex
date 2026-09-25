defmodule MuninWeb.RemindersLive do
  @moduledoc """
  P2's quiet promise: documents that carry a date should come back to you.
  Payment due dates from invoices, warranty windows from receipts, notice
  periods from contracts — all derived from the understanding layer's meta,
  nothing extra to maintain.
  """
  use MuninWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    docs = Munin.Documents.list_documents("", 500)
    {:ok, assign(socket, page_title: "Reminders", entries: entries(docs), today: Date.utc_today())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-8">
      <h1 class="text-2xl font-semibold mb-2">Reminders</h1>
      <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">
        Due dates, warranty windows and notice periods — derived automatically from your documents.
      </p>
      <%= if @entries == [] do %>
        <p class="text-zinc-500 dark:text-zinc-400">Nothing dated yet — upload invoices, receipts and contracts and they will show up here.</p>
      <% else %>
        <table class="m-table">
          <thead>
            <tr class="text-left dark:text-zinc-400">
              <th class="py-2 pr-4">Date</th><th class="py-2 pr-4">What</th><th class="py-2 pr-4">Document</th><th class="py-2 pr-4">Amount</th><th class="py-2">Status</th>
            </tr>
          </thead>
          <tbody>
            <%= for e <- @entries do %>
              <tr class="border-t border-zinc-200 dark:border-zinc-800">
                <td class="py-2 pr-4 whitespace-nowrap">{Date.to_iso8601(e.date)}</td>
                <td class="py-2 pr-4">{e.kind}{if e.label, do: " · " <> e.label, else: ""}</td>
                <td class="py-2 pr-4"><.link navigate={~p"/documents/#{e.doc.id}"} class="m-link">{e.doc.title || e.doc.filename}</.link></td>
                <td class="py-2 pr-4 whitespace-nowrap"><%= if e.amount do %>{:erlang.float_to_binary(e.amount + 0.0, decimals: 2)} {e.currency}<% end %></td>
                <td class="py-2"><span class={chip_class(e.urgency)}>{chip_text(e, @today)}</span></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp chip_class(:overdue), do: "rounded-full px-3 py-1 text-xs font-medium m-chip m-chip-red"
  defp chip_class(:soon), do: "rounded-full px-3 py-1 text-xs font-medium m-chip m-chip-yellow"
  defp chip_class(:info), do: "rounded-full px-3 py-1 text-xs font-medium m-chip m-chip-dim"
  defp chip_class(_), do: "rounded-full px-3 py-1 text-xs font-medium bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"

  defp entries(docs) do
    today = Date.utc_today()
    docs
    |> Enum.flat_map(&doc_entries(&1, today))
    |> Enum.sort_by(& &1.date, Date)
  end

  defp doc_entries(doc, today) do
    meta = doc.meta || %{}
    rem = meta["reminders"] || %{}
    inv = meta["invoice"] || %{}
    out = []

    out =
      if meta["doc_type"] in ["invoice", "receipt"] do
        case parse_date(rem["due_date"]) do
          nil -> out
          date -> [entry(doc, "Payment due", date, inv["total_gross"], inv["currency"], today) | out]
        end
      else
        out
      end

    out =
      if meta["doc_type"] == "receipt" and is_integer(rem["warranty_months"]) and rem["warranty_months"] > 0 do
        case parse_date(inv["date"]) do
          nil -> out
          date -> [entry(doc, "Warranty ends", add_months(date, rem["warranty_months"]), nil, nil, today) | out]
        end
      else
        out
      end

    out =
      if meta["doc_type"] == "contract" and is_integer(rem["notice_days"]) and rem["notice_days"] > 0 do
        [%{doc: doc, kind: "Contract notice", date: today, label: "#{rem["notice_days"]} days notice period", urgency: :info, amount: nil, currency: nil} | out]
      else
        out
      end

    out
  end

  defp entry(doc, kind, date, amount, currency, today) do
    days = Date.diff(date, today)
    urgency = cond do
      days < 0 -> :overdue
      days <= 14 -> :soon
      true -> :later
    end
    %{doc: doc, kind: kind, date: date, label: nil, urgency: urgency, amount: amount, currency: currency}
  end

  defp parse_date(s) when is_binary(s), do: s |> String.trim() |> parse_trimmed()
  defp parse_date(_), do: nil

  defp parse_trimmed(""), do: nil
  defp parse_trimmed(s) do
    case Date.from_iso8601(s) do
      {:ok, d} ->
        d
      _ ->
        case String.split(s, ".") |> Enum.map(&String.trim/1) do
          [d, m, y] when byte_size(y) == 4 ->
            case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
              {:ok, date} -> date
              _ -> nil
            end
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp add_months(date, 0), do: date
  defp add_months(date, n) when n > 0 do
    total = date.year * 12 + (date.month - 1) + n
    y = div(total, 12)
    m = rem(total, 12) + 1
    d = min(date.day, Date.days_in_month(Date.new!(y, m, 1)))
    Date.new!(y, m, d)
  end

  defp chip_text(%{urgency: :info}, _today), do: "notice"

  defp chip_text(%{date: date}, today) do
    days = Date.diff(date, today)
    cond do
      days < 0 -> "#{abs(days)}d overdue"
      days == 0 -> "today"
      true -> "in #{days}d"
    end
  end
end
