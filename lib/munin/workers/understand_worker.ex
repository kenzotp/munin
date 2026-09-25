defmodule Munin.Workers.UnderstandWorker do
  @moduledoc """
  Classify + extract after a successful read. When the local model was
  unreachable and cloud fallback is off, `understand/1` returns `{:retry,
  reason}` and writes nothing — this job snoozes (like ReadWorker) so it
  keeps waiting for the local model, however long it is away, instead of
  exhausting max_attempts or the document ever being recorded as
  "classification failed".
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 4,
    unique: [fields: [:args, :worker], states: [:available, :scheduled, :executing, :retryable], period: 3600]

  @retry_snooze_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case id |> Munin.Documents.get_document!() |> Munin.Understanding.understand() do
      {:ok, _doc} -> :ok
      {:retry, _reason} -> {:snooze, @retry_snooze_seconds}
    end
  end
end
