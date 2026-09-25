defmodule Munin.Money.FintsTest do
  use ExUnit.Case, async: false

  alias Munin.Money.Fints

  @row %{
    "booked_at" => "2026-01-15",
    "amount_cents" => -1999,
    "payer" => "Test GmbH",
    "description" => "Invoice 42",
    "iban" => "DE00TEST00000001",
    "external_id" => nil
  }

  describe "group_and_label/2 (row normalisation + per-account grouping/labels)" do
    test "normalizes a raw sidecar row into typed fields" do
      [{_label, [row]}] = Fints.group_and_label([@row], "Sparkasse")

      assert row.booked_at == ~D[2026-01-15]
      assert row.amount_cents == -1999
      assert row.payer == "Test GmbH"
      assert row.description == "Invoice 42"
      assert row.iban == "DE00TEST00000001"
      assert row.external_id == nil
    end

    test "labels a group '<base> …<last 4 IBAN digits>'" do
      assert [{"Sparkasse …0001", _rows}] = Fints.group_and_label([@row], "Sparkasse")
    end

    test "uses the given base label, not the hardcoded default" do
      assert [{"Girokonto …0001", _rows}] = Fints.group_and_label([@row], "Girokonto")
    end

    test "groups rows from different accounts into separate labeled buckets" do
      other = %{@row | "iban" => "DE00TEST00000099", "amount_cents" => 500}

      grouped = Fints.group_and_label([@row, other], "Sparkasse")
      labels = grouped |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert labels == ["Sparkasse …0001", "Sparkasse …0099"]

      {_label, rows_for_99} = Enum.find(grouped, fn {l, _} -> l == "Sparkasse …0099" end)
      assert [%{amount_cents: 500}] = rows_for_99
    end

    test "rows for the same account stay in one group" do
      second = %{@row | "amount_cents" => -500, "description" => "Second line"}

      assert [{"Sparkasse …0001", rows}] = Fints.group_and_label([@row, second], "Sparkasse")
      assert length(rows) == 2
    end

    test "falls back to '????' when the IBAN is missing" do
      row = %{@row | "iban" => nil}
      assert [{"Sparkasse …????", _rows}] = Fints.group_and_label([row], "Sparkasse")
    end
  end

  describe "error_message/2" do
    test "maps pin_error to a message naming FINTS_LOGIN/FINTS_PIN and the 3-attempt lock" do
      body = %{"detail" => %{"error" => "bank rejected the PIN or login", "pin_error" => true}}
      msg = Fints.error_message(502, body)

      assert msg =~ "PIN"
      assert msg =~ "FINTS_LOGIN"
      assert msg =~ "FINTS_PIN"
      assert msg =~ "3"
    end

    test "maps tan_timeout to a message telling the user to fetch again and approve" do
      body = %{"detail" => %{"error" => "approval was not given in time", "tan_timeout" => true}}
      msg = Fints.error_message(502, body)

      assert msg =~ "fetch again" or msg =~ "Fetch again"
      assert msg =~ "approve"
    end

    test "maps locked to a message about the account being locked" do
      body = %{"detail" => %{"error" => "online banking is locked", "locked" => true}}
      msg = Fints.error_message(502, body)

      assert msg =~ "locked"
    end

    test "maps tan_required to a message about typed TAN not being supported" do
      body = %{
        "detail" => %{
          "error" => "the bank asked for a typed TAN; only app-approval pushTAN is supported",
          "tan_required" => true
        }
      }

      msg = Fints.error_message(502, body)
      assert msg =~ "pushTAN"
    end

    test "keeps the existing DK/BPD propagation message" do
      body = %{"detail" => %{"error" => "could not fetch BPD"}}
      msg = Fints.error_message(502, body)

      assert msg =~ "DK database"
      assert msg =~ "propagates"
    end

    test "falls back to a plain HTTP message for an unrecognized detail" do
      body = %{"detail" => %{"error" => "something else entirely"}}
      msg = Fints.error_message(500, body)

      assert msg =~ "500"
      assert msg =~ "something else entirely"
    end

    test "a non-map body (e.g. a plain-text 500) never crashes" do
      msg = Fints.error_message(500, "internal server error")
      assert is_binary(msg)
      assert msg =~ "500"
    end
  end

  describe "configured?/0 and missing_keys/0" do
    setup do
      keys = ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)
      original = Map.new(keys, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(original, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      Enum.each(keys, &System.delete_env/1)
      :ok
    end

    test "missing_keys/0 lists every unset key" do
      assert Fints.missing_keys() == ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)
      refute Fints.configured?()
    end

    test "configured?/0 is true once every key is set" do
      System.put_env("FINTS_BLZ", "00000000")
      System.put_env("FINTS_URL", "https://example.invalid/fints")
      System.put_env("FINTS_LOGIN", "dummy")
      System.put_env("FINTS_PIN", "dummy")
      System.put_env("FINTS_PRODUCT_ID", "dummy")

      assert Fints.missing_keys() == []
      assert Fints.configured?()
    end

    test "fetch/2 short-circuits with a clear error when not configured" do
      assert {:error, msg} = Fints.fetch(~D[2026-01-01])
      assert msg =~ "not configured"
      assert msg =~ "FINTS_BLZ"
    end
  end
end
