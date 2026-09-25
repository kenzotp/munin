defmodule MuninWeb.DocumentsLive do
  @moduledoc """
  The vault list: newest first, live-updating, full-text search across
  filename, title and the read body. View chips: All / Invoices / Review.
  """
  use MuninWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, q: "", view: "all", docs: []) |> reload()}
  end

  @impl true
  def handle_params(%{"q" => q} = params, _uri, socket) do
    q = String.trim(q || "")
    view = params["view"] || "all"
    {:noreply, assign(socket, q: q, view: view) |> reload()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp reload(%{assigns: %{q: q, view: view}} = socket) do
    docs =
      q
      |> Munin.Documents.list_documents(300)
      |> filter_view(view)

    assign(socket, docs: docs)
  end

  defp filter_view(docs, "invoices"), do: Enum.filter(docs, &(&1.meta["doc_type"] in ["invoice", "receipt"]))
  defp filter_view(docs, "review"), do: Enum.filter(docs, &needs_review?/1)
  defp filter_view(docs, _), do: docs

  defp needs_review?(doc) do
    doc.meta["review_needed"] == true or get_in(doc.meta, ["invoice", "review_needed"]) == true
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/documents?#{%{q: String.trim(q), view: socket.assigns.view}}")}
  end

  def handle_event("view", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: ~p"/documents?#{%{q: socket.assigns.q, view: view}}")}
  end

  def handle_event("reread", %{"id" => id}, socket) do
    %{id: id}
    |> Munin.Workers.ReadWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Reading queued.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <div class="mb-4 flex flex-wrap items-center gap-3">
        <h1 class="text-2xl font-bold">Documents</h1>
        <div class="ml-auto flex gap-1.5">
          <.view_chip socket={@socket} view="all" current={@view} label="All" />
          <.view_chip socket={@socket} view="invoices" current={@view} label="Invoices" />
          <.view_chip socket={@socket} view="review" current={@view} label="Review" />
        </div>
      </div>

      <form phx-change="search" phx-submit="search" class="mb-4">
        <input
          type="search"
          name="q"
          value={@q}
          placeholder="Search filename, title and content…"
          class="w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
        />
      </form>

      <%= if @docs == [] do %>
        <p class="py-12 text-center text-sm text-zinc-500">
          <%= if @q == "" do %>
            The vault is empty. POST a file to /api/upload — or drop one in with Hugin.
          <% else %>
            Nothing matches “{@q}”.
          <% end %>
        </p>
      <% else %>
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500 uppercase dark:border-zinc-700">
              <th class="py-2 pr-3">Document</th>
              <th class="py-2 pr-3">Type</th>
              <th class="py-2 pr-3">Read</th>
              <th class="py-2 pr-3">Added</th>
              <th class="py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={doc <- @docs} class="border-b border-zinc-100 align-top dark:border-zinc-800">
              <td class="py-2 pr-3">
                <.link navigate={~p"/documents/#{doc.id}"} class="font-medium hover:underline">
                  {doc.title || doc.filename}
                </.link>
                <span class="block text-xs text-zinc-500">{doc.filename}</span>
                <span :if={doc.meta["vendor"]} class="text-xs text-zinc-400">{doc.meta["vendor"]}</span>
                <span :if={needs_review?(doc)} class="ml-1 rounded-full bg-red-100 px-1.5 text-xs text-red-700">
                  review
                </span>
              </td>
              <td class="py-2 pr-3 text-zinc-500">{doc.meta["doc_type"] || "—"}</td>
              <td class="py-2 pr-3">
                <span class={
                  "rounded-full px-2 py-0.5 text-xs " <>
                    case doc.read_status do
                      "done" -> "bg-emerald-100 text-emerald-700"
                      "failed" -> "bg-red-100 text-red-700"
                      "pending" -> "bg-amber-100 text-amber-700"
                      _ -> "bg-zinc-100 text-zinc-600"
                    end
                }>
                  {doc.read_status}
                </span>
              </td>
              <td class="py-2 pr-3 whitespace-nowrap text-zinc-500">
                {Calendar.strftime(doc.inserted_at, "%d.%m.%Y")}
              </td>
              <td class="py-2">
                <button
                  phx-click="reread"
                  phx-value-id={doc.id}
                  class="rounded border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  Read
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp view_chip(assigns) do
    ~H"""
    <button
      phx-click="view"
      phx-value-view={@view}
      class={
        "rounded-full px-3 py-1 text-xs font-medium " <>
          if @current == @view,
            do: "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900",
            else: "bg-zinc-100 text-zinc-600 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300"
      }
    >
      {@label}
    </button>
    """
  end
end
