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

  Two more things guard against the bank's own fraud/lockout logic:

    * Session state. Every fetch used to run the sidecar's full bootstrap
      dialog from scratch, which makes the bank register Munin as a brand
      new customer system each time — believed to cost an extra push
      notification per fetch. The sidecar's client_state (see
      `Munin.Money.FintsState`) is round-tripped through every fetch instead,
      so a returning system is recognized.

    * The lockout latch. If a fetch ever comes back pin_error or locked, the
      credentials that failed are latched (HMAC, never the PIN itself) and
      every further `fetch/2` with those same credentials is refused
      *without* contacting the sidecar — every dialog against the bank is a
      real attempt, and Sparkasse locks online banking after 3 wrong PINs.
      The latch clears itself the moment FINTS_LOGIN or FINTS_PIN changes,
      or by hand via `clear_latch!/0`.

  A process-global lock (`:global.set_lock/3`, zero retries) also makes sure
  only one fetch runs at a time on this node, across every LiveView and tab —
  a second attempt while one is in flight is refused immediately rather than
  opening a second dialog with the bank. The lock is tied to the fetching
  process and is released automatically if that process dies.
  """
  require Logger
  import Ecto.Query, only: [from: 2]
  alias Munin.Money
  alias Munin.Money.BankSync
  alias Munin.Money.FintsState
  alias Munin.Repo

  # pushTAN approval happens in the banking app and can take a couple of
  # minutes; give the sidecar dialog plenty of room rather than timing out
  # mid-poll.
  @receive_timeout :timer.minutes(9)

  @env_keys ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)

  @lock_resource {__MODULE__, :fetch}

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

  Refuses without contacting the sidecar when either guard is up: the
  current credentials are latched from a previous pin_error/locked response,
  or another fetch is already running on this node.

  Returns `{:ok, %{imported: n, duplicates: n, accounts: [%{label, imported,
  duplicates}], errors: [%{iban, error}]}}` or `{:error, reason}` with a
  human-readable reason.
  """
  def fetch(start_date, end_date \\ nil) do
    if configured?() do
      blz = System.get_env("FINTS_BLZ")
      login = System.get_env("FINTS_LOGIN")
      pin = System.get_env("FINTS_PIN")

      case latch_status(blz, login, pin) do
        {:latched, reason, _at} ->
          {:error, latch_message(reason)}

        :clear ->
          with_lock(fn -> do_fetch(blz, login, pin, start_date, end_date) end)
      end
    else
      {:error, "FinTS not configured — missing: " <> Enum.join(missing_keys(), ", ")}
    end
  end

  defp do_fetch(blz, login, pin, start_date, end_date) do
    end_date = end_date || Date.utc_today()

    payload =
      %{
        blz: blz,
        url: System.get_env("FINTS_URL"),
        login: login,
        pin: pin,
        product_id: System.get_env("FINTS_PRODUCT_ID"),
        start: Date.to_iso8601(start_date),
        end: Date.to_iso8601(end_date)
      }
      |> maybe_put_client_state(blz, login)

    case Req.post(vision_url("/fints/transactions"),
           req_opts(json: payload, receive_timeout: @receive_timeout)
         ) do
      {:ok, %{status: 200, body: %{"rows" => rows} = body}} ->
        if state = body["client_state"], do: save_state(blz, login, state)
        clear_latch!(blz, login)

        result = import_grouped(rows, body["accounts"] || [])

        Logger.info(
          "[fints] imported #{result.imported} (#{result.duplicates} duplicates) " <>
            "across #{length(result.accounts)} account(s)"
        )

        {:ok, result}

      {:ok, %{status: status, body: body}} ->
        maybe_latch_from_response(blz, login, pin, body)
        msg = error_message(status, body)
        Logger.warning("[fints] HTTP #{status}: #{msg}")
        {:error, msg}

      other ->
        Logger.warning("[fints] unexpected: #{inspect(other)}")
        {:error, "sidecar unreachable"}
    end
  end

  defp maybe_put_client_state(payload, blz, login) do
    case get_state(blz, login) do
      nil -> payload
      state -> Map.put(payload, :client_state, state)
    end
  end

  defp maybe_latch_from_response(blz, login, pin, body) do
    detail = detail_of(body)

    cond do
      detail["pin_error"] == true -> latch!(blz, login, pin, "pin_error")
      detail["locked"] == true -> latch!(blz, login, pin, "locked")
      true -> :ok
    end
  end

  defp detail_of(body) when is_map(body) do
    case body["detail"] do
      detail when is_map(detail) -> detail
      _ -> %{}
    end
  end

  defp detail_of(_body), do: %{}

  # --------------------------------------------------------------- locking

  defp with_lock(fun) do
    # LockRequesterId must be self() — a shared literal makes :global treat
    # every caller as "the same requester" and let them all through, which
    # defeats the whole point. self() is also what ties the lock to this
    # process, so it releases automatically if the process dies.
    lock_id = {@lock_resource, self()}

    if :global.set_lock(lock_id, [node()], 0) do
      try do
        fun.()
      after
        :global.del_lock(lock_id, [node()])
      end
    else
      {:error, "a bank fetch is already running"}
    end
  end

  # ----------------------------------------------------------------- state

  @doc "The stored client_state for this bank identity, or nil."
  def get_state(blz, login) do
    case Repo.get_by(FintsState, identity_hmac: identity_hmac(blz, login)) do
      nil -> nil
      row -> row.state
    end
  end

  @doc false
  def save_state(blz, login, state) when is_binary(state) do
    upsert(identity_hmac(blz, login), %{state: state})
    :ok
  end

  @doc """
  Deletes the stored client_state for this bank identity (the "Reset bank
  session" action) — the next fetch bootstraps fresh, as if no state had
  ever been saved. Leaves any lockout latch untouched.
  """
  def reset_state!(blz, login) do
    case Repo.get_by(FintsState, identity_hmac: identity_hmac(blz, login)) do
      nil -> :ok
      row -> row |> Ecto.Changeset.change(state: nil) |> Repo.update!() |> then(fn _ -> :ok end)
    end
  end

  def reset_state! do
    reset_state!(System.get_env("FINTS_BLZ"), System.get_env("FINTS_LOGIN"))
  end

  # ------------------------------------------------------------ sync record

  @doc """
  Records the outcome of a fetch attempt — time, trigger (`:scheduled` from
  the daily Oban job, `:manual` from the Import page button) and either the
  imported/duplicate counts or the error message. Purely an audit trail for
  the "last sync" status line on /money and /import; never read by
  `fetch/2` and never gates a future attempt (that's the latch's job).
  """
  def record_sync!(trigger, fetch_result) when trigger in [:scheduled, :manual] do
    outcome =
      case fetch_result do
        {:ok, %{imported: imported, duplicates: duplicates}} ->
          %{status: "ok", imported: imported, duplicates: duplicates}

        {:error, reason} ->
          %{status: "error", error_message: reason}
      end

    attrs =
      Map.merge(outcome, %{
        attempted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        trigger: Atom.to_string(trigger)
      })

    %BankSync{}
    |> BankSync.changeset(attrs)
    |> Repo.insert!()

    :ok
  end

  @doc "The most recently recorded sync attempt (scheduled or manual), or nil if none yet."
  def last_sync do
    Repo.one(from s in BankSync, order_by: [desc: s.attempted_at], limit: 1)
  end

  # ----------------------------------------------------------------- latch

  @doc """
  :clear, or {:latched, reason, at} when the given credentials exactly match
  the ones latched from a previous pin_error/locked response. Any credential
  change (a different HMAC) reads as :clear — the latch never blocks a
  corrected PIN or login.
  """
  def latch_status(blz, login, pin) do
    case Repo.get_by(FintsState, identity_hmac: identity_hmac(blz, login)) do
      %FintsState{latch_credential_hmac: hmac, latch_reason: reason, latch_at: at}
      when is_binary(hmac) ->
        if hmac == credential_hmac(blz, login, pin) do
          {:latched, reason, at}
        else
          :clear
        end

      _ ->
        :clear
    end
  end

  def latch_status do
    latch_status(System.get_env("FINTS_BLZ"), System.get_env("FINTS_LOGIN"), System.get_env("FINTS_PIN"))
  end

  defp latch!(blz, login, pin, reason) do
    upsert(identity_hmac(blz, login), %{
      latch_credential_hmac: credential_hmac(blz, login, pin),
      latch_reason: reason,
      latch_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    :ok
  end

  @doc """
  Clears the lockout latch — the "I checked the PIN in the banking app"
  button. Leaves the stored client_state untouched.
  """
  def clear_latch!(blz, login) do
    case Repo.get_by(FintsState, identity_hmac: identity_hmac(blz, login)) do
      nil ->
        :ok

      row ->
        row
        |> Ecto.Changeset.change(latch_credential_hmac: nil, latch_reason: nil, latch_at: nil)
        |> Repo.update!()
        |> then(fn _ -> :ok end)
    end
  end

  def clear_latch! do
    clear_latch!(System.get_env("FINTS_BLZ"), System.get_env("FINTS_LOGIN"))
  end

  defp latch_message("locked") do
    "The bank already locked online banking after too many wrong PIN attempts — refusing to " <>
      "contact it again. Check FINTS_LOGIN/FINTS_PIN in the banking app first, then use " <>
      "\"I checked the PIN in the banking app\" to allow one more attempt."
  end

  defp latch_message(_reason) do
    "The bank rejected these credentials last time — refusing to contact it again. Check " <>
      "FINTS_LOGIN/FINTS_PIN in the banking app first; Sparkasse locks online banking after " <>
      "3 wrong PINs. Use \"I checked the PIN in the banking app\" to allow one more attempt."
  end

  defp upsert(identity_hmac, attrs) do
    keys = Map.keys(attrs)

    %FintsState{}
    |> FintsState.changeset(Map.put(attrs, :identity_hmac, identity_hmac))
    |> Repo.insert!(on_conflict: {:replace, keys}, conflict_target: :identity_hmac)
  end

  # ------------------------------------------------------------------ hmac

  @doc "HMAC-SHA256(secret_key_base, \"<blz>|<login>\") — a login change starts a fresh row."
  def identity_hmac(blz, login), do: hmac("#{blz}|#{login}")

  @doc """
  HMAC-SHA256(secret_key_base, "<blz>|<login>|<pin>") of the credentials that
  failed. Never the PIN itself, never an unkeyed hash of it.
  """
  def credential_hmac(blz, login, pin), do: hmac("#{blz}|#{login}|#{pin}")

  defp hmac(message) do
    key = MuninWeb.Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, key, message) |> Base.encode16(case: :lower)
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

  defp req_opts(extra) do
    Keyword.merge(Application.get_env(:munin, :fints_req_options, []), extra)
  end

  defp vision_url(path), do: Path.join(vision_base(), path)
  defp vision_base, do: System.get_env("VISION_URL", "http://munin_vision:8100")
end
