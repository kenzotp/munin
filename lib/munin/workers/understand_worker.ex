defmodule Munin.Workers.UnderstandWorker do
  @moduledoc """
  Classify + extract after a successful read. When the local model was
  unreachable and cloud fallback is off, `understand/1` returns `{:retry,
  reason}` and writes nothing — this job errors out so Oban retries it
  (max_attempts backoff) instead of the document ever being recorded as
  "classification failed".
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 4,
    unique: [fields: [:args, :worker], states: [:available, :scheduled, :executing, :retryable], period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case id |> Munin.Documents.get_document!() |> Munin.Understanding.understand() do
      {:ok, _doc} -> :ok
      {:retry, reason} -> {:error, reason}
    end
  end
end
