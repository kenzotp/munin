defmodule MuninWeb.DocumentLive do
  @moduledoc """
  One document: the extracted understanding (type, vendor, invoice money
  fields with the checksum verdict) and the review form. "Confirm" is the
  human in the loop — it clears review_needed and stores the corrected fields.
  """
  use MuninWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    doc = Munin.Documents.get_document!(id)
    {:ok, assign(socket, doc: doc, inv: (doc.meta["invoice"] || %{}) |> stringify())}
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {k, if(is_number(v), do: to_string(v), else: v || "")} end)

  @impl true
  def handle_event("save", params, socket) do
    doc = socket.assigns.doc
    inv_old = doc.meta["invoice"] || %{}

    if doc.meta["doc_type"] in ["invoice", "receipt"] or params["total_gross"] != "" do
      with {:ok, total} <- num(params["total_gross"]),
           {:ok, vat} <- num(params["vat_amount"]),
           {:ok, net} <- num(params["net_amount"]) do
        invoice = %{
          "vendor" => params["vendor"],
          "number" => params["number"],
          "date" => params["date"],
          "currency" => params["currency"],
          "total_gross" => total,
          "vat_amount" => vat,
          "net_amount" => net,
          "checksum_ok" => abs(net + vat - total) <= 0.02,
          "review_needed" => false
        }

        {:noreply, save(socket, doc, params, invoice)}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not save — #{reason}.")}
      end
    else
      {:noreply, save(socket, doc, params, inv_old)}
    end
  end

  defp save(socket, doc, params, invoice) do
    meta =
      (doc.meta || %{})
      |> Map.put("doc_type", params["doc_type"])
      |> Map.put("scope", params["scope"])
      |> Map.put("vendor", params["vendor"])
      |> Map.put("invoice", invoice)
      |> Map.drop(["review_needed", "review_reason"])

    {:ok, doc} =
      doc
      |> Munin.Documents.Document.changeset(%{title: params["title"], meta: meta})
      |> Munin.Repo.update()

    assign(socket, doc: doc, inv: stringify(invoice)) |> put_flash(:info, "Saved.")
  end

  # German-or-plain amount input → `{:ok, float}` (euros, not cents) or
  # `{:error, reason}`. Empty input keeps the historical "0.0" behaviour;
  # anything else reuses `Munin.Money.parse_euro/1` (which already handles
  # "1.234,56", "1234,56" and "1234.56") so there is only one amount parser in
  # the app.
  defp num(nil), do: {:ok, 0.0}
  defp num(""), do: {:ok, 0.0}

  defp num(s) do
    case Munin.Money.parse_euro(s) do
      {:ok, cents} -> {:ok, cents / 100.0}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6">
      <Layouts.flash_group flash={@flash} />
      <.link navigate={~p"/documents"} class="text-sm text-sky-500 hover:underline">← Documents</.link>

      <div class="mt-3 flex items-center gap-3">
        <h1 class="text-2xl font-bold">{@doc.title || @doc.filename}</h1>
        <%= if review_needed?(@doc) do %>
          <span class="rounded-full bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700">
            needs review: {review_reason(@doc)}
          </span>
        <% end %>
      </div>
      <p class="mt-1 text-xs text-zinc-500">
        {@doc.filename} · {@doc.mime} · {doc_size(@doc)} · read {@doc.read_status} · from {@doc.source}
      </p>

      <form phx-submit="save" class="mt-6 space-y-4">
        <div class="grid gap-3 sm:grid-cols-2">
          <.field label="Title" name="title" value={@doc.title || ""} />
          <.field label="Vendor" name="vendor" value={@doc.meta["vendor"] || ""} />
          <label class="block text-xs text-zinc-500">
            Type
            <select name="doc_type" class="mt-1 w-full rounded border border-zinc-300 px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
              { Phoenix.HTML.Form.options_for_select(~w(invoice receipt contract letter ticket statement other), @doc.meta["doc_type"] || "other") }
            </select>
          </label>
          <label class="block text-xs text-zinc-500">
            Scope
            <select name="scope" class="mt-1 w-full rounded border border-zinc-300 px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
              { Phoenix.HTML.Form.options_for_select(~w(business private), @doc.meta["scope"] || "private") }
            </select>
          </label>
        </div>

        <fieldset class="rounded-xl border border-zinc-200 p-4 dark:border-zinc-700">
          <legend class="px-1 text-xs font-semibold text-zinc-500">Invoice fields</legend>
          <div class="grid gap-3 sm:grid-cols-3">
            <.field label="Number" name="number" value={@inv["number"] || ""} />
            <.field label="Date" name="date" value={@inv["date"] || ""} />
            <.field label="Currency" name="currency" value={@inv["currency"] || "EUR"} />
            <.field label="Net" name="net_amount" value={@inv["net_amount"] || ""} />
            <.field label="VAT" name="vat_amount" value={@inv["vat_amount"] || ""} />
            <.field label="Total (gross)" name="total_gross" value={@inv["total_gross"] || ""} />
          </div>
          <p class="mt-2 text-xs text-zinc-500">
            Checksum: {if @inv["checksum_ok"] in [true, "true"], do: "✓ net + VAT = total", else: "⚠ does not add up (yet)"}
          </p>
        </fieldset>

        <%= if @doc.body_text do %>
          <details class="rounded-xl border border-zinc-200 p-4 text-xs dark:border-zinc-700">
            <summary class="cursor-pointer text-zinc-500">Read text</summary>
            <pre class="mt-2 whitespace-pre-wrap text-zinc-600">{@doc.body_text}</pre>
          </details>
        <% end %>

        <button type="submit" class="rounded-lg bg-sky-600 px-4 py-2 text-sm font-medium text-white hover:bg-sky-500">
          Save &amp; confirm
        </button>
      </form>
    </div>
    """
  end

  defp field(assigns) do
    ~H"""
    <label class="block text-xs text-zinc-500">
      {@label}
      <input
        type="text"
        name={@name}
        value={@value}
        class="mt-1 w-full rounded border border-zinc-300 px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900"
      />
    </label>
    """
  end

  defp review_needed?(doc) do
    doc.meta["review_needed"] == true or get_in(doc.meta, ["invoice", "review_needed"]) == true
  end

  defp review_reason(doc) do
    doc.meta["review_reason"] || get_in(doc.meta, ["invoice", "review_reason"]) || "unverified"
  end

  defp doc_size(doc) do
    if doc.size do
      kb = div(doc.size, 1024)
      if kb > 1024, do: "#{div(kb, 1024)} MB", else: "#{kb} KB"
    else
      "?"
    end
  end
end
