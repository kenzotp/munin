defmodule Munin.Workers.UnderstandWorker do
  @moduledoc "Classify + extract after a successful read."
  use Oban.Worker,
    queue: :default,
    max_attempts: 4,
    unique: [fields: [:args, :worker], states: [:available, :scheduled, :executing, :retryable], period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    id
    |> Munin.Documents.get_document!()
    |> Munin.Understanding.understand()

    :ok
  end
end
