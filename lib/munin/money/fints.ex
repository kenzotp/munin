defmodule Munin.Money.Fints do
  @moduledoc """
  P3 bank ingestion via FinTS (PIN/TAN), talking to the python-fints sidecar.
  Read-only by design: the tool fetches statements and can never initiate
  payments.

  The DK product registration ID identifies MUNIN to the banks — it lives in
  .env (FINTS_PRODUCT_ID), never in the repo. Open-source rule: each
  self-hoster registers their own free ID at fints.org and sets the same env
  vars; shipping an ID inside the repo is explicitly forbidden by DK.
  """
  require Logger
  alias Munin.Money

  @timeout 180_000

  @env_keys ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)

  def configured? do
    missing_keys() == []
  end

  def missing_keys do
    @env_keys |> Enum.filter(&(System.get_env(&1) in [nil, ""]))
  end

  @doc """
  Fetch statements for the date range and feed them through the standard
  import (content-hash dedupe makes re-fetches a no-op). Returns
  {imported, duplicates} or {:error, reason}.
  """
  def fetch(start_date, end_date \\ nil) do
    if configured?() do
      end_date = end_date || Date.utc_today()

      payload = %{
        blz: System.get_env("FINTS_BLZ"),
        url: System.get_env("FINTS_URL"),
        login: System.get_env("FINTS_LOGIN"),
        pin: System.get_env("FINTS_PIN"),
        product_id: System.get_env("FINTS_PRODUCT_ID"),
        start: Date.to_iso8601(start_date),
        end: Date.to_iso8601(end_date)
      }

      case Req.post(vision_url("/fints/transactions"), json: payload, receive_timeout: @timeout) do
        {:ok, %{status: 200, body: %{"rows" => rows}}} ->
          rows = Enum.map(rows, &normalize_row/1)
          account = System.get_env("FINTS_ACCOUNT", "Sparkasse")
          {imported, dups} = Money.import_rows(account, rows, "fints")
          Logger.info("[fints] imported #{imported} (#{dups} duplicates)")
          {:ok, {imported, dups}}

        {:ok, %{status: status, body: body}} ->
          # FastAPI wraps HTTPException payloads under "detail"
          detail = body["detail"] || %{}
          err = (is_map(detail) && (detail["error"] || detail["message"])) || inspect(body)
          tan = is_map(detail) && detail["tan_required"] == true

          msg =
            cond do
              tan ->
                "The bank wants a TAN approval (S-pushTAN) — interactive flow not wired yet. " <>
                  err

              String.contains?(err, "could not fetch BPD") ->
                "The bank does not accept our product registration ID yet — the DK database " <>
                  "propagates new IDs over several working days. Retry in a few days " <>
                  "(or check BLZ/URL)."

              true ->
                err
            end

          Logger.warning("[fints] HTTP #{status}: #{msg}")
          {:error, msg}

        other ->
          Logger.warning("[fints] unexpected: #{inspect(other)}")
          {:error, "sidecar unreachable"}
      end
    else
      {:error, "FinTS not configured — missing: " <> Enum.join(missing_keys(), ", ")}
    end
  end

  defp normalize_row(r) do
    %{
      booked_at: Date.from_iso8601!(binary_part(r["booked_at"], 0, 10)),
      amount_cents: r["amount_cents"],
      payer: r["payer"],
      description: r["description"],
      iban: r["iban"],
      external_id: r["external_id"]
    }
  end

  defp vision_url(path), do: Path.join(vision_base(), path)
  defp vision_base, do: System.get_env("VISION_URL", "http://munin_vision:8100")
end
