defmodule Munin.Workers.ReadWorker do
  @moduledoc """
  Runs the reading ladder for one document, then hands it to the
  understanding worker. Backoff on failure; a successful read (or a genuinely
  empty one) chains classification/extraction.
  """
  use Oban.Worker,
    queue: :reading,
    max_attempts: 5,
    unique: [fields: [:args, :worker], states: [:available, :scheduled, :executing, :retryable], period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    doc =
      id
      |> Munin.Documents.get_document!()
      |> Munin.Documents.read_document!()

    if doc.read_status in ["done", "empty"] do
      %{id: doc.id}
      |> Munin.Workers.UnderstandWorker.new()
      |> Oban.insert()
    end

    :ok
  end
end
