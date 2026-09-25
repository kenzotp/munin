defmodule Munin.Workers.ReadWorker do
  @moduledoc """
  Runs the reading ladder for one document, then hands it to the
  understanding worker. A "pending" read (sidecar asleep, or the local model
  unreachable with cloud fallback off) snoozes the job instead of finishing
  it, so it really does come back — this is not a failure and must not burn
  an attempt. A successful read (or a genuinely empty one) chains
  classification/extraction; a genuine failure just ends the job (backoff via
  max_attempts).
  """
  use Oban.Worker,
    queue: :reading,
    max_attempts: 5,
    unique: [fields: [:args, :worker], states: [:available, :scheduled, :executing, :retryable], period: 3600]

  # Local model cold loads cost 40-45s; give it real room to come back before
  # trying again.
  @pending_snooze_seconds 90

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    doc =
      id
      |> Munin.Documents.get_document!()
      |> Munin.Documents.read_document!()

    case doc.read_status do
      "pending" ->
        {:snooze, @pending_snooze_seconds}

      status when status in ["done", "empty"] ->
        %{id: doc.id}
        |> Munin.Workers.UnderstandWorker.new()
        |> Oban.insert()

        :ok

      _ ->
        :ok
    end
  end
end
