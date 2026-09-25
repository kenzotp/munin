defmodule Munin.Money.Wave1Test do
  use Munin.DataCase, async: false

  alias Munin.Money
  alias MuninWeb.Format

  defp month_date(offset, day) do
    today = Date.utc_today()
    total = today.year * 12 + today.month - 1 - offset
    y = div(total, 12)
    m = rem(total, 12) + 1
    Date.new!(y, m, min(day, Date.days_in_month(Date.new!(y, m, 1))))
  end

  defp row(date, cents, payer, desc \\ "Zeile") do
    %{booked_at: date, amount_cents: cents, payer: payer, description: desc, iban: nil, external_id: nil}
  end

  # ------------------------------------------------------------------ format

  test "German money format: thousands dot, comma cents" do
    assert Format.money(123_456) == "1.234,56 €"
    assert Format.money(-9_999) == "-99,99 €"
    assert Format.money(5) == "0,05 €"
    assert Format.money(0) == "0,00 €"
  end

  test "German date format" do
    assert Format.date(~D[2026-09-25]) == "25.09.2026"
  end

  # ------------------------------------------------------------------- rules

  test "a learned rule wins over built-in classification at import" do
    {:ok, _} = Money.create_rule(%{kind: "classify", pattern: "shell", category: "transport", scope: "business"})

    Money.import_rows("T1", [row(~D[2026-09-01], -7_210, "SHELL TANKSTELLE", "Kraftstoff")])
    [t] = Munin.Repo.all(Munin.Money.Transaction)

    assert t.scope == "business"
    assert t.category == "transport"
  end

  test "apply_rules! reclassifies stored lines but leaves rule-less lines alone" do
    Money.import_rows("T2", [
      row(~D[2026-09-02], -7_210, "SHELL TANKSTELLE", "Kraftstoff"),
      row(~D[2026-09-03], -1_500, "SOMETHING ELSE", "mystery")
    ])

    # manual edit on the rule-less line: must survive
    t2 = Munin.Repo.get_by!(Munin.Money.Transaction, payer: "SOMETHING ELSE")
    Munin.Repo.update!(Ecto.Changeset.change(t2, scope: "business"))

    {:ok, _} = Money.create_rule(%{kind: "classify", pattern: "shell", category: "transport", scope: "business"})
    n = Money.apply_rules!()

    assert n == 1
    assert Munin.Repo.get_by!(Munin.Money.Transaction, payer: "SHELL TANKSTELLE").scope == "business"
    assert Munin.Repo.get_by!(Munin.Money.Transaction, payer: "SOMETHING ELSE").scope == "business"
  end

  test "rule_from_line creates a rule from a stored line and applies it" do
    # a payee the builtin keyword rules do NOT classify
    Money.import_rows("T3", [
      row(~D[2026-09-04], -4_990, "DATENWERK NORD GMBH", "Server"),
      row(~D[2026-08-04], -4_990, "DATENWERK NORD GMBH", "Server")
    ])

    t = Munin.Repo.get_by!(Munin.Money.Transaction, booked_at: ~D[2026-09-04])
    Munin.Repo.update!(Ecto.Changeset.change(t, scope: "business", category: "saas"))

    assert {:ok, rule} = Money.rule_from_line(Munin.Repo.reload(t))
    assert rule.pattern == "DATENWERK NORD"
    assert Money.apply_rules!() == 1
    assert Munin.Repo.get_by!(Munin.Money.Transaction, booked_at: ~D[2026-08-04]).scope == "business"
  end

  # --------------------------------------------------------------- transfers

  test "transfer detection finds cross-account pairs and marking retires them from sums" do
    Money.import_rows("HAUPT", [row(month_date(0, 3), -50_000, "MEIN KONTO", "Umbuchung")])
    Money.import_rows("NEBEN", [row(month_date(0, 4), 50_000, "MEIN KONTO", "Umbuchung")])

    pairs = Money.transfer_candidates()
    assert [{out, inn}] = pairs
    assert out.account == "HAUPT" and inn.account == "NEBEN"

    :ok = Money.mark_transfer!(out.id, inn.id)
    assert Munin.Repo.get!(Munin.Money.Transaction, out.id).is_transfer
    assert Munin.Repo.get!(Munin.Money.Transaction, inn.id).is_transfer
    assert Money.transfer_candidates() == []

    stats = Money.cockpit(6)
    # the pair no longer inflates in/out
    refute Enum.any?(stats.monthly, fn {_y, _m, i, o} -> i >= 50_000 or o >= 50_000 end)
  end

  # ----------------------------------------------------------- subscriptions

  test "subscription detail: monthly detection, next charge, price hike" do
    rows = [
      row(month_date(4, 5), -999, "TEST-ABO GMBH", "Abo"),
      row(month_date(3, 5), -999, "TEST-ABO GMBH", "Abo"),
      row(month_date(2, 5), -999, "TEST-ABO GMBH", "Abo"),
      row(month_date(1, 5), -1_999, "TEST-ABO GMBH", "Abo price up")
    ]

    Money.import_rows("SUBS", rows)
    subs = Money.subscription_detail()
    s = Enum.find(subs, &(&1.payee == "TEST ABO"))

    assert s
    assert s.interval == 1
    assert s.charge_cents == -999
    assert s.next_charge
    assert s.hike == %{from: -999, to: -1_999}
  end

  test "amount-varied merchants are not subscriptions" do
    Money.import_rows("SUBS4", [
      row(month_date(2, 3), -4_123, "EDEKA MARKT BONN", "Lebensmittel"),
      row(month_date(1, 7), -8_811, "EDEKA MARKT BONN", "Lebensmittel"),
      row(month_date(0, 2), -2_745, "EDEKA MARKT BONN", "Lebensmittel")
    ])

    refute Enum.any?(Money.subscription_detail(), &String.contains?(&1.payee, "EDEKA"))
  end

  test "bank statement noise never shows up as a subscription" do
    Money.import_rows("SUBS5", [
      row(month_date(2, 3), -599, "SPARKASSE", "Entgeltabschluss"),
      row(month_date(1, 3), -599, "SPARKASSE", "Entgeltabschluss"),
      row(month_date(0, 3), -599, "SPARKASSE", "Entgeltabschluss")
    ])

    refute Enum.any?(Money.subscription_detail(), &String.contains?(&1.payee, "SPARKASSE"))
  end

  test "yearly recurrence (2 charges ~12 months apart) is detected" do
    Money.import_rows("SUBS2", [
      row(month_date(12, 2), -8_700, "VERSICHERUNG X", "Beitrag"),
      row(month_date(1, 2), -8_700, "VERSICHERUNG X", "Beitrag")
    ])

    s = Enum.find(Money.subscription_detail(), &(&1.payee == "VERSICHERUNG X"))
    assert s
    assert s.interval == 12
    assert s.yearly_cents == -8_700
  end

  test "ignore_sub rule hides a payee from the radar" do
    Money.import_rows("SUBS3", [
      row(month_date(2, 5), -999, "MIETE VERMIETER", "Miete"),
      row(month_date(1, 5), -999, "MIETE VERMIETER", "Miete"),
      row(month_date(0, 5), -999, "MIETE VERMIETER", "Miete")
    ])

    {:ok, _} = Money.create_rule(%{kind: "ignore_sub", pattern: "miete"})
    refute Enum.any?(Money.subscription_detail(), &String.contains?(&1.payee, "MIETE"))
  end
end
