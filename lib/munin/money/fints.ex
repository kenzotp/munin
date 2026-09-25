defmodule Munin.Money.Fints do
  @moduledoc """
  P3 bank ingestion via FinTS (PIN/TAN), talking to the python-fints sidecar.
  Read-only by design: the tool fetches statements and can never initiate
  payments.

  SCA: the sidecar approves the dialog via a decoupled two-step mechanism
  (e.g. Sparkasse pushTAN 2.0) — Mika approves in the banking app, no TAN is
  ever typed here. That poll can take a couple of minutes, so the HTTP call
  to the sidecar is given a long receive timeout.

  The DK product registration ID identifies MUNIN to the banks — it lives in
  .env (FINTS_PRODUCT_ID), never in the repo. Open-source rule: each
  self-hoster registers their own free ID at fints.org and sets the same env
  vars; shipping an ID inside the repo is explicitly forbidden by DK.
  """
  require Logger
  alias Munin.Money

  # pushTAN approval happens in the banking app and can take a couple of
  # minutes; give the sidecar dialog plenty of room rather than timing out
  # mid-poll.
  @receive_timeout :timer.minutes(9)

  @env_keys ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)

  def configured? do
    missing_keys() == []
  end

  def missing_keys do
    @env_keys |> Enum.filter(&(System.get_env(&1) in [nil, ""]))
  end

  @doc """
  Fetch statements for the date range and feed them through the standard
  import, one label per account (content-hash dedupe makes re-fetches a
  no-op).

  Returns `{:ok, %{imported: n, duplicates: n, accounts: [%{label, imported,
  duplicates}], errors: [%{iban, error}]}}` or `{:error, reason}` with a
  human-readable reason.
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

      case Req.post(vision_url("/fints/transactions"),
             json: payload,
             receive_timeout: @receive_timeout
           ) do
        {:ok, %{status: 200, body: %{"rows" => rows} = body}} ->
          result = import_grouped(rows, body["accounts"] || [])

          Logger.info(
            "[fints] imported #{result.imported} (#{result.duplicates} duplicates) " <>
              "across #{length(result.accounts)} account(s)"
          )

          {:ok, result}

        {:ok, %{status: status, body: body}} ->
          msg = error_message(status, body)
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

  # ------------------------------------------------------------- grouping

  @doc """
  Groups normalized rows by IBAN and labels each group
  "<base> …<last 4 IBAN digits>", `base` defaulting to FINTS_ACCOUNT (or
  "Sparkasse"). Exposed (not private) so tests can check grouping/labelling
  without going through HTTP.
  """
  def group_and_label(rows, base \\ nil) do
    base = base || System.get_env("FINTS_ACCOUNT", "Sparkasse")

    rows
    |> Enum.map(&normalize_row/1)
    |> Enum.group_by(& &1.iban)
    |> Enum.map(fn {iban, group_rows} -> {label_for(base, iban), group_rows} end)
  end

  defp label_for(base, iban) do
    last4 =
      cond do
        is_binary(iban) and byte_size(iban) >= 4 -> binary_part(iban, byte_size(iban) - 4, 4)
        is_binary(iban) -> iban
        true -> "????"
      end

    "#{base} …#{last4}"
  end

  defp import_grouped(rows, sidecar_accounts) do
    per_account =
      rows
      |> group_and_label()
      |> Enum.map(fn {label, group_rows} ->
        {imported, dups} = Money.import_rows(label, group_rows, "fints")
        %{label: label, imported: imported, duplicates: dups}
      end)

    errors =
      sidecar_accounts
      |> Enum.filter(&(is_map(&1) and &1["error"] not in [nil, false]))
      |> Enum.map(&%{iban: &1["iban"], error: &1["error"]})

    %{
      imported: Enum.reduce(per_account, 0, &(&1.imported + &2)),
      duplicates: Enum.reduce(per_account, 0, &(&1.duplicates + &2)),
      accounts: per_account,
      errors: errors
    }
  end

  # ------------------------------------------------------------ messages

  @doc """
  Maps a non-200 sidecar response to a clear English message. Public and
  pure so tests can cover it directly. A non-map body (e.g. a plain-text 500
  from a proxy in front of the sidecar) never crashes this.
  """
  def error_message(status, body) when not is_map(body) do
    "HTTP #{status}: #{inspect(body)}"
  end

  def error_message(status, body) do
    detail = body["detail"]
    detail = if is_map(detail), do: detail, else: %{}
    err = detail["error"] || detail["message"] || inspect(body)

    cond do
      detail["pin_error"] == true ->
        "The bank rejected the PIN or login (#{err}). Check FINTS_LOGIN and FINTS_PIN in " <>
          ".env before retrying — Sparkasse locks online banking after 3 wrong PINs."

      detail["tan_timeout"] == true ->
        "Approval was not given in time (#{err}). Fetch again and approve the push in your " <>
          "banking app promptly."

      detail["locked"] == true ->
        "Online banking is locked (#{err})."

      detail["tan_required"] == true ->
        "The bank asked for a typed TAN — only app-approval pushTAN (S-pushTAN) is " <>
          "supported. #{err}"

      String.contains?(err, "could not fetch BPD") ->
        "The bank does not accept our product registration ID yet — the DK database " <>
          "propagates new IDs over several working days. Retry in a few days " <>
          "(or check BLZ/URL)."

      true ->
        "HTTP #{status}: #{err}"
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
