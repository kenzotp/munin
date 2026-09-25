defmodule Munin.Workers.BankSyncWorker do
  @moduledoc """
  Pulls the last 14 days of bank statements once a day, so transactions
  arrive without a manual click on the Import page. Scheduled by
  `Oban.Plugins.Cron` at 05:00 Europe/Berlin (see `cron_plugin/3`, wired up
  in config/runtime.exs) — switched off with env `BANK_SYNC=off`, the time
  overridable with `BANK_SYNC_CRON`.

  Does nothing but log when FinTS isn't configured. Every guard against
  hammering the bank already lives in `Munin.Money.Fints.fetch/2` — the
  lockout latch and the single-fetch lock — so this worker adds no retry
  loop of its own: `max_attempts: 1`, it fetches once, records the outcome
  (ok or error, including a latched/locked refusal) and finishes. Oban can
  therefore never turn a pin_error or a locked response into a second bank
  attempt.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger
  alias Munin.Money.Fints

  @timezone "Europe/Berlin"
  @lookback_days 14
  @default_cron "0 5 * * *"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Fints.configured?() do
      start_date = Date.add(today(), -@lookback_days)
      result = Fints.fetch(start_date)
      Fints.record_sync!(:scheduled, result)
      :ok
    else
      Logger.info("[bank_sync] skipped — FinTS not configured")
      :ok
    end
  end

  @doc "Today's date in Europe/Berlin — the window fetch/2 is given starts 14 days before this."
  def today, do: DateTime.now!(@timezone) |> DateTime.to_date()

  @doc """
  Builds the `Oban.Plugins.Cron` tuple for this worker, or `nil` when the
  schedule should be left out of Oban's plugin list entirely — either
  `BANK_SYNC=off`, or FinTS isn't configured (nothing to sync, no point
  scheduling an attempt that would just log and stop). Pure — no
  `System.get_env` inside — so config/runtime.exs supplies the env reads and
  this stays directly testable.
  """
  def cron_plugin(fints_configured?, bank_sync_env, cron_env) do
    if fints_configured? and bank_sync_env != "off" do
      {Oban.Plugins.Cron, timezone: @timezone, crontab: [{cron_env || @default_cron, __MODULE__}]}
    end
  end

  @doc "Whether the daily schedule is on right now (mirrors cron_plugin/3's own gate, read live)."
  def enabled? do
    System.get_env("BANK_SYNC") != "off" and Fints.configured?()
  end

  @doc """
  The next scheduled run, or `nil` when the schedule is off. Reads
  `BANK_SYNC_CRON` for the hour/minute (a plain "M H * * *" daily
  expression — any other field is ignored, since this only ever needs to
  say when the *next* run is, not evaluate arbitrary cron syntax).
  """
  def next_run_at do
    if enabled?() do
      {hour, minute} = parse_hour_minute(System.get_env("BANK_SYNC_CRON", @default_cron))
      now = DateTime.now!(@timezone)
      today_at = DateTime.new!(DateTime.to_date(now), Time.new!(hour, minute, 0), @timezone)

      if DateTime.compare(today_at, now) == :gt do
        today_at
      else
        DateTime.new!(Date.add(DateTime.to_date(now), 1), Time.new!(hour, minute, 0), @timezone)
      end
    end
  end

  @doc """
  One-line status for /money and /import: the last recorded sync outcome,
  plus the next scheduled run when the daily job is on. German date format,
  Berlin time throughout.
  """
  def status_line do
    base =
      case Fints.last_sync() do
        nil ->
          "Never synced"

        %{status: "ok", attempted_at: at, imported: imported} ->
          "Bank synced #{format_date_time(at)} — #{imported} new line#{plural(imported)}"

        %{status: "error", attempted_at: at, error_message: msg} ->
          "Last sync failed #{format_time(at)}: #{msg}"
      end

    case next_run_at() do
      nil -> base
      at -> base <> " · next #{format_date_time(at)}"
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp parse_hour_minute(cron) do
    with [min, hour | _] <- String.split(cron),
         {m, ""} <- Integer.parse(min),
         {h, ""} <- Integer.parse(hour) do
      {h, m}
    else
      _ -> {5, 0}
    end
  end

  defp format_date_time(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!(@timezone) |> Calendar.strftime("%d.%m.%Y %H:%M")

  defp format_time(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!(@timezone) |> Calendar.strftime("%H:%M")
end
