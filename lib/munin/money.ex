defmodule Munin.Money do
  @moduledoc """
  The money core. Bank-API-free by design until the DK registration lands:
  lines arrive via CSV import (real Sparkasse exports parse as-is) or the
  simulator (`source: "simulated"`). Everything downstream — matching, cockpit,
  EÜR — is the same code real banks will feed in P3.

  Dedupe: Firefly's content hash (account | date | amount | payer | purpose |
  external id), unique index per account — re-imports can never double-book.
  Matching: beancount-import-style — exact amount, ±45-day window, vendor
  token overlap on payer/purpose (never fuzzy names).
  """
  import Ecto.Query
  alias Munin.Repo
  alias Munin.Money.Transaction
  alias Munin.Money.Rule
  alias Munin.Documents.Document
  require Logger

  # ------------------------------------------------------------------ rules

  @rules [
    {"income", "business", ["zuuna"]},
    {"saas", "business", ["openrouter", "openai", "anthropic", "github", "jetbrains", "figma", "notion", "aws", "amazon web services", "hetzner", "netcup", "namecheap", "cloudflare", "stripe fee", "unpkg"]},
    {"fees", "business", ["gebühr", "entgelt", "kartenpflege", "kontoführung", "rücklastschrift"]},
    {"hardware", "business", ["conrad", "alternate", "mindfactory", "caseking", "reichelt"]},
    {"insurance", "private", ["versicherung", "krankenkasse", "barmer", "allianz", "huk"]},
    {"rent", "private", ["miete"]},
    {"groceries", "private", ["edeka", "rewe", "lidl", "aldi", "penny", "netto", "kaufland", "dm ", "rossmann"]},
    {"transport", "private", ["db vertrieb", "bahn", "deutschlandticket", "shell", "aral", "esso", "deutschebahn"]},
    {"health", "private", ["apotheke", "zahnarzt", "praxis"]},
    {"subscriptions", "private", ["netflix", "spotify", "disney", "steam"]},
    {"dining", "private", ["restaurant", "gasthaus", "mcdonald", "burger", "pizza", "eiscafé", "café"]}
  ]

  def list_rules do
    Repo.all(from r in Rule, order_by: [asc: r.kind, asc: r.inserted_at])
  end

  def create_rule(attrs) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> Repo.insert()
  end

  def delete_rule!(id), do: Repo.delete!(Repo.get!(Rule, id))

  @doc """
  One click from a bank line: remember "this payee → this category + scope"
  and use it for every future import. The pattern is the normalized payee.
  """
  def rule_from_line(%Transaction{} = t) do
    pattern =
      case rule_pattern(t) do
        "" -> String.slice(t.description || "", 0, 30)
        p -> p
      end

    %Rule{}
    |> Rule.changeset(%{kind: "classify", pattern: pattern, category: t.category, scope: t.scope})
    |> Repo.insert()
  end

  defp rule_pattern(t) do
    (t.payer || "")
    |> String.upcase()
    |> String.replace(~r/\d{4,}/, " ")
    |> String.split(~r/[^A-Z0-9&.]+/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  def classify_rules do
    Repo.all(from r in Rule, where: r.kind == "classify", order_by: [asc: r.inserted_at])
  end

  defp ignore_patterns do
    Repo.all(from r in Rule, where: r.kind == "ignore_sub", select: r.pattern)
    |> Enum.map(&String.downcase/1)
  end

  @doc "Keyword rules → {category, scope}. DB rules first, then built-ins; default other/private."
  def classify(%{} = row), do: classify_with(classify_rules(), row)

  def classify_with(rules, row) do
    hay = String.downcase((row[:payer] || "") <> " " <> (row[:description] || ""))

    case Enum.find(rules, &String.contains?(hay, String.downcase(&1.pattern))) do
      %Rule{} = r ->
        row |> Map.put(:category, r.category || "other") |> Map.put(:scope, r.scope || "private")

      nil ->
        builtin_classify(row)
    end
  end

  # The classification a DB rule alone produces — nil when no rule matches.
  # apply_rules!/0 uses this so manual overrides that no rule covers survive.
  defp classify_rule_only(rules, row) do
    hay = String.downcase((row[:payer] || "") <> " " <> (row[:description] || ""))

    case Enum.find(rules, &String.contains?(hay, String.downcase(&1.pattern))) do
      %Rule{} = r -> {r.category || "other", r.scope || "private"}
      nil -> nil
    end
  end

  defp builtin_classify(row) do
    hay = String.downcase((row[:payer] || "") <> " " <> (row[:description] || ""))
    hit =
      Enum.find(@rules, fn {_cat, _scope, kws} -> Enum.any?(kws, &String.contains?(hay, &1)) end)
    case hit do
      {cat, scope, _} -> row |> Map.put(:category, cat) |> Map.put(:scope, scope)
      nil -> row |> Map.put(:category, if(row.amount_cents >= 0, do: "income", else: "other")) |> Map.put(:scope, "private")
    end
  end

  # ----------------------------------------------------------------- import

  @doc """
  Rows: %{booked_at: %Date{}, amount_cents: int, payer: str, description: str,
  iban: str, external_id: str}. Classified + hashed; on_conflict nothing.
  Returns {imported, duplicates}.
  """
  def import_rows(account, rows, source \\ "csv") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    rules = classify_rules()

    maps =
      rows
      |> Enum.map(&classify_with(rules, &1))
      |> Enum.map(fn r ->
        hash = hash_line(account, r)
        %{
          id: Ecto.UUID.generate(),
          account: account,
          external_id: r[:external_id],
          hash: hash,
          booked_at: r.booked_at,
          amount_cents: r.amount_cents,
          currency: "EUR",
          payer: r[:payer],
          description: r[:description],
          iban: r[:iban],
          category: r.category,
          scope: r.scope,
          source: source,
          inserted_at: now,
          updated_at: now
        }
      end)

    {imported, _} =
      Repo.insert_all(Transaction, maps,
        on_conflict: :nothing,
        conflict_target: [:account, :hash]
      )

    {imported, max(length(rows) - imported, 0)}
  end

  @doc """
  Replay the learned classify rules over every stored line. Only lines a rule
  actually matches are touched — manual edits that no rule covers survive.
  Returns the number of updated lines.
  """
  def apply_rules! do
    rules = classify_rules()

    if rules == [] do
      0
    else
      Repo.all(Transaction)
      |> Enum.map(fn t ->
        row = %{payer: t.payer, description: t.description, amount_cents: t.amount_cents}

        case classify_rule_only(rules, row) do
          {cat, scope} when cat != t.category or scope != t.scope -> {t, cat, scope}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(0, fn {t, cat, scope}, acc ->
        Repo.update!(Ecto.Changeset.change(t, category: cat, scope: scope))
        acc + 1
      end)
    end
  end

  defp hash_line(account, r) do
    :sha256
    |> :crypto.hash(
      "#{account}|#{Date.to_iso8601(r.booked_at)}|#{r.amount_cents}|#{r[:payer]}|#{r[:description]}|#{r[:external_id]}"
    )
    |> Base.encode16(case: :lower)
  end

  def simulated? do
    Repo.exists?(from t in Transaction, where: t.source == "simulated")
  end

  def list_transactions(q, scope, account, limit) do
    base =
      from t in Transaction,
        order_by: [desc: t.booked_at, desc: t.inserted_at],
        limit: ^limit

    base =
      if q != "" do
        like = "%#{q}%"
        from t in base, where: ilike(t.payer, ^like) or ilike(t.description, ^like)
      else
        base
      end

    base =
      case scope do
        "business" -> from t in base, where: t.scope == "business"
        "private" -> from t in base, where: t.scope == "private"
        _ -> base
      end

    case account do
      a when a in [nil, "", "all"] -> base
      a -> from t in base, where: t.account == ^a
    end
  end

  @doc "All accounts that ever had a line: {name, line_count, latest_date}."
  def accounts do
    Repo.all(
      from t in Transaction,
        group_by: t.account,
        order_by: [desc: count(t.id)],
        select: {t.account, count(t.id), max(t.booked_at)}
    )
  end

  def delete_simulated! do
    {n, _} = Repo.delete_all(from t in Transaction, where: t.source == "simulated")
    n
  end

  # ----------------------------------------------------------------- parsing

  @doc "Tolerant CSV: Sparkasse/generic German exports. Returns {rows, errors}."
  def parse_csv(text) do
    lines =
      String.split(text, ["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] -> {[], []}
      [header | data] ->
        sep = if String.contains?(header, ";"), do: ";", else: if(String.contains?(header, "\t"), do: "\t", else: ",")
        cols = map_columns(split_line(header, sep))
        {rows, errors} =
          data
          |> Enum.map(&split_line(&1, sep))
          |> Enum.map_reduce([], fn cells, errs ->
            case row_from(cells, cols) do
              {:ok, row} -> {row, errs}
              {:error, reason} -> {nil, [reason | errs]}
            end
          end)
        {Enum.reject(rows, &is_nil/1), Enum.reverse(errors)}
    end
  end

  defp split_line(line, sep) do
    line
    |> String.split(sep)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp map_columns(header) do
    %{
      date: find_col(header, ["buchungstag", "wertstellung", "datum", "date"]),
      amount: find_col(header, ["betrag", "umsatz", "amount", "betrag (eur)"]),
      payer: find_col(header, ["zahlungspflicht", "zahlungsbeteilig", "auftraggeber", "empfänger", "name", "payee"]),
      description: find_col(header, ["verwendungszweck", "buchungstext", "beschreibung", "description", "vorgang"]),
      iban: find_col(header, ["iban", "kontonummer"])
    }
  end

  defp find_col(header, keys) do
    down = Enum.map(header, &String.downcase/1)
    Enum.find_index(down, fn h -> Enum.any?(keys, &String.contains?(h, &1)) end)
  end

  defp row_from(cells, cols) do
    with {:ok, date} <- pick_date(cells, cols.date),
         {:ok, cents} <- pick_cents(cells, cols.amount) do
      {:ok,
       %{
         booked_at: date,
         amount_cents: cents,
         payer: get_cell(cells, cols.payer),
         description: get_cell(cells, cols.description),
         iban: get_cell(cells, cols.iban),
         external_id: nil
       }}
    else
      {:error, r} -> {:error, r}
    end
  end

  defp get_cell(cells, idx) when is_integer(idx) and idx < length(cells), do: Enum.at(cells, idx)
  defp get_cell(_cells, _idx), do: nil

  defp pick_date(_cells, nil), do: {:error, "no date column found"}
  defp pick_date(cells, idx) do
    case Enum.at(cells, idx) do
      nil -> {:error, "missing date"}
      raw -> parse_german_date(raw)
    end
  end

  defp parse_german_date(raw) do
    raw = String.trim(raw)
    case Date.from_iso8601(raw) do
      {:ok, d} ->
        {:ok, d}
      _ ->
        case String.split(raw, ".") do
          [d, m, y] when byte_size(y) >= 4 ->
            case Date.new(String.to_integer(binary_part(y, 0, 4)), String.to_integer(m), String.to_integer(d)) do
              {:ok, date} -> {:ok, date}
              _ -> {:error, "bad date: #{raw}"}
            end
          _ -> {:error, "bad date: #{raw}"}
        end
    end
  rescue
    _ -> {:error, "bad date: #{raw}"}
  end

  defp pick_cents(_cells, nil), do: {:error, "no amount column found"}
  defp pick_cents(cells, idx) do
    case Enum.at(cells, idx) do
      nil -> {:error, "missing amount"}
      raw -> parse_euro(raw)
    end
  end

  @doc "\"1.234,56-\" / \"-1234.56\" / \"1234,56 EUR\" → signed integer cents."
  def parse_euro(raw) do
    raw = raw |> String.replace(~r/[^\d,.\-]/, "") |> String.trim()
    {neg, body} =
      if String.contains?(raw, "-") do
        {true, String.replace(raw, "-", "")}
      else
        {false, raw}
      end

    normalized =
      if String.contains?(body, ",") do
        String.replace(String.replace(body, ".", ""), ",", ".")
      else
        body
      end

    case Float.parse(normalized) do
      {f, _} -> {:ok, round(if(neg, do: -f, else: f) * 100)}
      :error -> {:error, "bad amount: #{raw}"}
    end
  rescue
    _ -> {:error, "bad amount: #{raw}"}
  end

  # --------------------------------------------------------------- matching

  @doc "Ranked bank lines that could be the payment for this invoice document."
  def candidates_for(%Document{} = doc, limit \\ 6) do
    inv = get_in(doc.meta, ["invoice"]) || %{}
    cents = gross_cents(inv["total_gross"])

    if cents == 0 do
      []
    else
      # Paying an invoice leaves a NEGATIVE bank line; match against the outflow.
      base =
        from t in Transaction,
          where: t.amount_cents == ^(-cents) and is_nil(t.matched_document_id)

      base =
        case invoice_date(inv, doc) do
          %Date{} = d ->
            from t in base, where: t.booked_at >= ^(Date.add(d, -3)) and t.booked_at <= ^(Date.add(d, 45))
          _ ->
            base
        end

      tokens = vendor_tokens(inv["vendor"])

      base
      |> Repo.all()
      |> Enum.map(fn t -> {t, score(t, tokens)} end)
      |> Enum.filter(fn {_t, s} -> s > 0 end)
      |> Enum.sort(fn {_, a}, {_, b} -> a >= b end)
      |> Enum.take(limit)
    end
  end

  defp gross_cents(n) when is_number(n) and n != 0, do: round(n * 100)
  defp gross_cents(_), do: 0

  defp invoice_date(inv, doc) do
    (inv["date"] || get_in(doc.meta, ["reminders", "due_date"]))
    |> case do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(String.slice(s, 0, 10)) do
          {:ok, d} -> d
          _ -> nil
        end
      _ -> nil
    end
  end

  defp vendor_tokens(nil), do: []
  defp vendor_tokens(v) do
    v
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u)
    |> Enum.filter(&(String.length(&1) >= 4))
    |> Enum.uniq()
  end

  defp score(t, tokens) do
    hay = String.downcase((t.payer || "") <> " " <> (t.description || ""))
    Enum.count(tokens, &String.contains?(hay, &1))
  end

  @doc "Auto-confirm candidates with at least one vendor-token hit. Returns matches made."
  def auto_match_all! do
    unmatched_docs()
    |> Enum.reduce(0, fn doc, acc ->
      case candidates_for(doc, 1) do
        [{line, s}] when s >= 1 ->
          case Munin.Jev.invoice_matches_line?(doc, line) do
            {:ok, n} ->
              if n >= Munin.Jev.auto_threshold() do
                # Jev blesses the pair: auto-match, keeping its confidence.
                doc
                |> note_jev!(%{"noul" => Float.round(n, 3), "matched" => true})
                |> then(&confirm!(&1, line))
                acc + 1
              else
                # Jev doubts it: leave the pair in the /money/tx review queue.
                note_jev!(doc, %{"noul" => Float.round(n, 3), "matched" => false, "line_id" => line.id})
                acc
              end

            # Jev disabled (no key) or unreachable: legacy behaviour decides.
            _ ->
              confirm!(doc, line)
              acc + 1
          end

        _ -> acc
      end
    end)
  end

  # Records the Jev second opinion under meta["jev"] and returns the updated
  # struct, so a following confirm!/2 merges its matched flags on top.
  defp note_jev!(%Document{} = doc, jev) do
    meta = Map.put(doc.meta || %{}, "jev", jev)

    doc
    |> Ecto.Changeset.change(meta: meta)
    |> Repo.update!()
  end

  def confirm!(%Document{} = doc, %Transaction{} = line) do
    Repo.update!(Ecto.Changeset.change(line, matched_document_id: doc.id))

    meta =
      doc.meta
      |> Map.put("matched_line_id", line.id)
      |> Map.put("matched", true)

    doc
    |> Ecto.Changeset.change(meta: meta)
    |> Repo.update!()

    {:ok, line}
  end

  def unmatched_docs do
    from(d in Document,
      where: fragment("coalesce(?->'invoice'->>'total_gross', '')", d.meta) not in ["", "0"],
      where: fragment("coalesce(?->>'matched_line_id', '')", d.meta) == ""
    )
    |> Repo.all()
  end

  def matched_line(doc) do
    case doc.meta["matched_line_id"] do
      nil -> nil
      id -> Repo.get(Transaction, id)
    end
  end

  # -------------------------------------------------------------- transfers

  @doc """
  Internal transfers between own accounts: same amount, opposite sign, ±4
  days, neither side marked yet. Each inflow pairs at most once. These pairs
  are income+spend double-counts today — one click retires both sides.
  """
  def transfer_candidates do
    since = Date.add(Date.utc_today(), -400)

    outs =
      Repo.all(
        from t in Transaction,
          where: t.amount_cents < 0 and t.is_transfer == false and t.booked_at >= ^since
      )

    ins =
      Repo.all(
        from t in Transaction,
          where: t.amount_cents > 0 and t.is_transfer == false and t.booked_at >= ^since
      )

    {pairs, _used} =
      outs
      |> Enum.sort_by(& &1.booked_at, {:desc, Date})
      |> Enum.map_reduce(MapSet.new(), fn t, used ->
        candidate =
          ins
          |> Enum.filter(fn i ->
            i.amount_cents == -t.amount_cents and i.account != t.account and
              abs(Date.diff(i.booked_at, t.booked_at)) <= 4 and not MapSet.member?(used, i.id)
          end)
          |> Enum.min_by(&abs(Date.diff(&1.booked_at, t.booked_at)), fn -> nil end)

        case candidate do
          nil -> {nil, used}
          i -> {{t, i}, MapSet.put(used, i.id)}
        end
      end)

    Enum.reject(pairs, &is_nil/1)
  end

  def mark_transfer!(out_id, in_id) do
    {2, _} =
      Repo.update_all(from(t in Transaction, where: t.id in ^[out_id, in_id]), set: [is_transfer: true])

    :ok
  end

  def unmark_transfer!(id) do
    t = Repo.get!(Transaction, id)
    Repo.update!(Ecto.Changeset.change(t, is_transfer: false))
    :ok
  end

  # --------------------------------------------------------------- cockpit

  def cockpit(months \\ 6) do
    since = Date.add(Date.utc_today(), -30 * months)
    lines = Repo.all(from t in Transaction, where: t.booked_at >= ^since, order_by: [desc: t.booked_at])
    spent = Enum.filter(lines, &(&1.amount_cents < 0 and not &1.is_transfer))

    monthly =
      lines
      |> Enum.filter(&(not &1.is_transfer))
      |> Enum.group_by(fn t -> {t.booked_at.year, t.booked_at.month} end)
      |> Enum.map(fn {{y, m}, ls} ->
        {y, m,
         ls |> Enum.filter(&(&1.amount_cents > 0)) |> Enum.reduce(0, &(&1.amount_cents + &2)),
         ls |> Enum.filter(&(&1.amount_cents < 0)) |> Enum.reduce(0, &(&1.amount_cents + &2)) |> abs()}
      end)
      |> Enum.sort()

    {biz_spend, priv_spend} =
      spent
      |> Enum.reduce({0, 0}, fn t, {b, p} ->
        if t.scope == "business", do: {b + abs(t.amount_cents), p}, else: {b, p + abs(t.amount_cents)}
      end)

    top_payees =
      spent
      |> Enum.group_by(&normal_payee/1)
      |> Enum.map(fn {payer, ls} -> {payer, length(ls), Enum.reduce(ls, 0, &(&1.amount_cents + &2))} end)
      |> Enum.sort_by(fn {_p, _c, sum} -> sum end)
      |> Enum.take(8)

    today = Date.utc_today()
    this_month = Enum.filter(lines, &(&1.booked_at.year == today.year and &1.booked_at.month == today.month and not &1.is_transfer))
    vat = eur(latest_year())

    %{
      monthly: monthly,
      biz_spend: biz_spend,
      priv_spend: priv_spend,
      top_payees: top_payees,
      subscriptions: subscriptions_for(Enum.filter(lines, &(&1.amount_cents < 0 and not &1.is_transfer))),
      missing_receipts: missing_receipts(spent),
      total_lines: length(lines),
      month_in: this_month |> Enum.filter(&(&1.amount_cents > 0)) |> Enum.reduce(0, &(&1.amount_cents + &2)),
      month_out: this_month |> Enum.filter(&(&1.amount_cents < 0)) |> Enum.reduce(0, &(&1.amount_cents + &2)) |> abs(),
      vat_output: vat.output_vat,
      vat_input: vat.input_vat,
      docs_review: docs_to_review_count(),
      deadlines: upcoming_deadlines()
    }
  end

  defp normal_payee(t), do: String.slice(t.payer || t.description || "?", 0, 26)

  @doc """
  The subscriptions radar over real lines: payees that recur monthly (3+
  charges in distinct months) or yearly (2+ charges ~12 months apart), with
  next-charge estimate and price-hike detection. `ignore_sub` rules hide
  payees.
  """
  def subscription_detail do
    since = Date.add(Date.utc_today(), -400)

    Repo.all(
      from t in Transaction,
        where: t.amount_cents < 0 and t.is_transfer == false and t.booked_at >= ^since
    )
    |> subscriptions_for()
  end

  # Sparkasse statement words that recur but are never subscriptions.
  @sub_noise ["kartenzahlung", "entgeltabschluss", "sagt danke", "kreditkartenabrechnung", "n.v.", "onlinebanking", "werteingabe", "dauerauftrag", "lastschrift aktiv"]

  defp subscriptions_for(lines) do
    ignored = ignore_patterns()

    lines
    |> Enum.reject(&sub_noise?(&1))
    |> Enum.group_by(&sub_payee/1)
    |> Enum.reject(fn {payee, _} -> payee == "" or String.length(payee) < 4 or Enum.any?(ignored, &String.contains?(String.downcase(payee), &1)) end)
    |> Enum.map(&sub_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.monthly_cents, :desc)
  end

  defp sub_noise?(t) do
    hay = String.downcase((t.payer || "") <> " " <> (t.description || ""))
    Enum.any?(@sub_noise, &String.contains?(hay, &1))
  end

  # Group key: payer with IBANs, reference numbers and legal forms stripped,
  # so "REWE MARKT GMBH FILIALE 4477" groups with "REWE MARKT". Unicode-safe
  # (umlauts survive).
  @legal_forms ~w(GMBH MBH AG SE NV SA KG OHG CO UG EK INC LTD)

  defp sub_payee(t) do
    (t.payer || t.description || "")
    |> String.upcase()
    |> String.replace(~r/\p{L}{2}\d{2}[\p{L}\p{N}]{10,30}/u, " ")
    |> String.replace(~r/\d{4,}/, " ")
    |> String.split(~r/[^\p{L}\p{N}&.]+/u)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&(&1 in @legal_forms))
    |> Enum.take(3)
    |> Enum.join(" ")
  end

  # A subscription needs the SAME amount recurring: monthly = the most common
  # charge appears in 3+ distinct months, yearly = 2+ charges ~12 months apart.
  # Anything else (groceries, card payments) has no dominant amount and falls out.
  defp sub_summary({payee, ls}) do
    ls = Enum.sort_by(ls, & &1.booked_at, {:desc, Date})
    newest = hd(ls)
    {mode, _count} = Enum.max_by(Enum.frequencies(Enum.map(ls, & &1.amount_cents)), fn {_, n} -> n end)

    mode_months =
      ls
      |> Enum.filter(&(&1.amount_cents == mode))
      |> Enum.map(&{&1.booked_at.year, &1.booked_at.month})
      |> Enum.uniq()

    span = month_diff(List.last(ls).booked_at, newest.booked_at)

    interval =
      cond do
        length(mode_months) >= 3 -> 1
        length(mode_months) >= 2 and span >= 10 -> 12
        true -> nil
      end

    case interval do
      nil -> nil
      interval -> sub_card(newest, length(ls), mode, payee, interval)
    end
  end

  defp sub_card(newest, charges, mode_cents, payee, interval) do
    next = add_months(newest.booked_at, interval)
    stale = Date.diff(Date.utc_today(), next) > 45

    %{
      payee: payee,
      scope: newest.scope,
      account: newest.account,
      charge_cents: mode_cents,
      interval: interval,
      monthly_cents: if(interval == 12, do: div(mode_cents, 12), else: mode_cents),
      yearly_cents: if(interval == 12, do: mode_cents, else: mode_cents * 12),
      next_charge: if(stale, do: nil, else: next),
      last_charge: newest.booked_at,
      stale: stale,
      charges: charges,
      hike: maybe_hike(newest.amount_cents, mode_cents)
    }
  end

  # The newest charge left the usual amount by >= 2 EUR and >= 5% -> a hike.
  defp maybe_hike(newest_cents, mode_cents) do
    m_abs = abs(mode_cents)
    n_abs = abs(newest_cents)

    if n_abs != m_abs and n_abs - m_abs >= 200 and n_abs * 100 >= m_abs * 105 do
      %{from: mode_cents, to: newest_cents}
    end
  end

  defp month_diff(%Date{} = from, %Date{} = to) do
    (to.year - from.year) * 12 + (to.month - from.month)
  end

  # Business spend without a matching document — receipts you should dig up.
  defp missing_receipts(lines) do
    lines
    |> Enum.filter(&(&1.amount_cents < 0 and &1.scope == "business" and is_nil(&1.matched_document_id) and &1.category not in ["fees"]))
    |> Enum.take(25)
  end

  defp docs_to_review_count do
    Repo.one(
      from d in Document,
        where: d.read_status == "pending" or
                 fragment("coalesce(?->>'review_needed','false') = 'true'", d.meta) or
                 fragment("coalesce(?->'invoice'->>'review_needed','false') = 'true'", d.meta),
        select: count(d.id)
    )
  end

  # Payment due dates derived from documents: overdue (last 90 days) + the
  # next 7 days. Warranty/notice dates stay on the reminders page.
  defp upcoming_deadlines do
    today = Date.utc_today()

    from(d in Document, where: fragment("coalesce(?->'reminders'->>'due_date','') <> ''", d.meta))
    |> Repo.all()
    |> Enum.flat_map(fn d ->
      case d.meta["reminders"]["due_date"] do
        s when is_binary(s) and s != "" ->
          case Date.from_iso8601(String.slice(s, 0, 10)) do
            {:ok, date} -> [%{date: date, doc_id: d.id, title: d.title || d.filename}]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> then(fn ds ->
      %{
        overdue: Enum.count(ds, &(&1.date < today and Date.diff(today, &1.date) <= 90)),
        soon:
          ds
          |> Enum.filter(&(&1.date >= today and Date.diff(&1.date, today) <= 7))
          |> Enum.sort_by(& &1.date)
          |> Enum.take(5)
      }
    end)
  end

  # ------------------------------------------------------------------- tax

  @doc "EÜR-style sums for one year + a rough USt estimate. Estimates, not filings."
  def eur(year) do
    lines =
      Repo.all(
        from t in Transaction,
          where:
            t.scope == "business" and t.is_transfer == false and
              fragment("extract(year from ?)", t.booked_at) == ^year
      )

    revenue = lines |> Enum.filter(&(&1.amount_cents > 0)) |> Enum.reduce(0, &(&1.amount_cents + &2))
    by_cat =
      lines
      |> Enum.filter(&(&1.amount_cents < 0))
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, ls} -> {cat, Enum.reduce(ls, 0, &(&1.amount_cents + &2))} end)
      |> Enum.sort()

    expenses = by_cat |> Enum.reduce(0, fn {_, s}, acc -> acc + s end) |> abs()

    # Output VAT assumed 19% on all revenue (estimate!); input VAT from matched invoices.
    output_vat = round(revenue - revenue / 1.19)

    input_vat =
      lines
      |> Enum.map(& &1.matched_document_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn id -> Repo.get!(Document, id) end)
      |> Enum.reduce(0, fn d, acc -> acc + (get_in(d.meta, ["invoice", "vat_amount"]) || 0) end)
      |> round()

    %{
      year: year,
      revenue: revenue,
      by_cat: by_cat,
      expenses: expenses,
      profit: revenue - expenses,
      output_vat: output_vat,
      input_vat: input_vat
    }
  end

  def latest_year do
    case Repo.one(from t in Transaction, select: max(t.booked_at)) do
      %Date{} = d -> d.year
      _ -> Date.utc_today().year
    end
  end

  # ------------------------------------------------------------- simulator

  @doc "8 months of plausible German business+private lines, marked source=simulated."
  def seed_demo! do
    :rand.seed(:exsss, {1, 2, 3})
    today = Date.utc_today()
    # 7 months back so the whole demo window sits inside the cockpit's 6-month view
    start = today |> Date.add(-210) |> then(fn d -> Date.new!(d.year, d.month, 1) end)

    months =
      Enum.map(0..7, fn i ->
        d = add_months(start, i)
        base = [
          row(d, 1, 420_000, "KUNDE NORDSEE DIGITAL GMBH", "Rechnung ZUUNA 2026-0#{i + 1} Projektarbeit", "business"),
          row(d, 2, 185_000, "KUNDE SUEDWIND SOFTWARE AG", "Rechnung ZUUNA Beratungspauschale", "business"),
          row(d, 3, -98_000, "VONOVIA SE", "Miete Wohnung", "private"),
          row(d, 4, -1_234, "OPENROUTER", "AI API Nutzung monatlich", "business"),
          row(d, 5, -4_890, "HETZNER ONLINE GMBH", "Server CX41 Rechnung", "business"),
          row(d, 6, -6_712, "AMAZON WEB SERVICES EMEA", "AWS Cloud Rechnung", "business"),
          row(d, 7, -2_158, "GITHUB INC", "GitHub Team Plan", "business"),
          row(d, 8, -1_299, "NETFLIX.COM", "Abo monatlich", "private"),
          row(d, 9, -999, "SPOTIFY", "Premium Abo", "private"),
          row(d, 12, -89_00, "ALLRISE VERSICHERUNG AG", "Berufshaftpflicht Beitrag", "business")
        ]
        jitter =
          Enum.flat_map(1..4, fn k ->
            [
              row(d, 10 + k, -(:rand.uniform(9_000) + 3_500), Enum.random(["EDEKA MARKT", "REWE MARKT", "LIDL"]), "LEBENSMITTEL", "private"),
              row(d, 20 + k, -(:rand.uniform(4_000) + 2_000), Enum.random(["SHELL TANKSTELLE", "ARAL"]), "Kraftstoff", "private")
            ]
          end) ++
          [
            row(d, 15, -4_900, "DB VERTRIEB GMBH", "Deutschlandticket", "business"),
            row(d, 16, -3_499, "APOTHEKE AM MARKT", "Rezept", "private")
          ]

        Enum.map(base ++ jitter, fn {d2, day, cents, payer, desc, scope} ->
          day = min(day, Date.days_in_month(d2))
          %{booked_at: Date.new!(d2.year, d2.month, day), amount_cents: cents, payer: payer, description: desc, iban: nil, external_id: nil, scope: scope}
        end)
      end)

    rows = List.flatten(months)
    # scope pre-seeded: classify() would mostly agree; force ours, keep the hash stable
    rows = Enum.map(rows, &Map.put(&1, :category, classify(&1).category))
    {imported, dups} = import_rows("SIMULATED", rows, "simulated")

    # two demo invoices so matching has something to chew on (Hetzner + OpenRouter)
    demo_invoices!()

    {imported, dups}
  end

  defp row(date, day, cents, payer, desc, scope), do: {date, day, cents, payer, desc, scope}

  defp add_months(date, n) do
    total = date.year * 12 + (date.month - 1) + n
    y = div(total, 12)
    m = rem(total, 12) + 1
    Date.new!(y, m, 1)
  end

  defp demo_invoices! do
    Enum.each(
      [
        %{
          vendor: "Hetzner Online GmbH",
          number: "INV-2026-0815",
          date: shift_iso(2, 6),
          total_gross: 48.9,
          vat_amount: 7.81,
          net_amount: 41.09
        },
        %{
          vendor: "OpenRouter",
          number: "OR-88231",
          date: shift_iso(1, 3),
          total_gross: 12.34,
          vat_amount: 1.97,
          net_amount: 10.37
        }
      ],
      fn inv ->
        sha = :sha256 |> :crypto.hash("demo-invoice-" <> inv.number) |> Base.encode16(case: :lower)
        meta = %{
          "doc_type" => "invoice",
          "scope" => "business",
          "vendor" => inv.vendor,
          "invoice" => inv,
          "reminders" => %{"due_date" => "", "warranty_months" => 0, "notice_days" => 0}
        }

        case Repo.get_by(Document, sha256: sha) do
          nil ->
            Repo.insert!(%Document{
              sha256: sha,
              path: "simulated",
              filename: "Rechnung_#{String.replace(inv.vendor, " ", "_")}_#{inv.number}.pdf",
              mime: "application/pdf",
              size: 12_345,
              source: "simulated",
              title: "#{inv.vendor} — #{inv.number}",
              body_text: "Rechnung #{inv.number} von #{inv.vendor}, Gesamtbetrag #{inv.total_gross} EUR.",
              read_status: "done",
              meta: meta
            })

          _ -> :ok
        end
      end
    )
  end

  defp shift_iso(months_ago, day) do
    d = add_months(Date.utc_today(), -months_ago)
    Date.new!(d.year, d.month, min(day, Date.days_in_month(d))) |> Date.to_iso8601()
  end
end
