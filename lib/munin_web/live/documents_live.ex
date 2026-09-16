defmodule MuninWeb.DocumentsLive do
  @moduledoc """
  The vault list: newest first, live-updating, full-text search across
  filename, title and the read body. P1 keeps it deliberately spartan.
  """
  use MuninWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, q: "", docs: Munin.Documents.list_documents())}
  end

  @impl true
  def handle_params(%{"q" => q}, _uri, socket) do
    q = String.trim(q || "")
    {:noreply, assign(socket, q: q, docs: Munin.Documents.list_documents(q))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/documents?q=#{String.trim(q)}")}
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
    <div class="mx-auto max-w-4xl p-6">
      <h1 class="mb-4 text-2xl font-bold">Documents</h1>

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
              <th class="py-2 pr-3">Source</th>
              <th class="py-2 pr-3">Read</th>
              <th class="py-2 pr-3">Added</th>
              <th class="py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={doc <- @docs} class="border-b border-zinc-100 align-top dark:border-zinc-800">
              <td class="py-2 pr-3">
                <span class="font-medium">{doc.filename}</span>
                <span :if={doc.title} class="block text-xs text-zinc-500">{doc.title}</span>
                <span :if={doc.body_text} class="mt-0.5 line-clamp-2 block text-xs text-zinc-400">
                  {String.slice(doc.body_text, 0, 180)}
                </span>
              </td>
              <td class="py-2 pr-3 text-zinc-500">{doc.source}</td>
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
end
