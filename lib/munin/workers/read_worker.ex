defmodule Munin.Workers.ReadWorker do
  @moduledoc "Runs the reading ladder for one document, with backoff on failure."
  use Oban.Worker, queue: :reading, max_attempts: 5, unique: [fields: [:args, :worker], states: [:available, :scheduled, :executing, :retryable], period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    id
    |> Munin.Documents.get_document!()
    |> Munin.Documents.read_document!()

    :ok
  end
end
