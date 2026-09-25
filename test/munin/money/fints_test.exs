defmodule Munin.Money.FintsTest do
  use Munin.DataCase, async: false

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

  describe "identity_hmac/2 and credential_hmac/3 (S6: HMAC key derivation)" do
    test "identity_hmac is deterministic and depends on both blz and login" do
      a = Fints.identity_hmac("50010517", "user1")
      assert a == Fints.identity_hmac("50010517", "user1")
      refute a == Fints.identity_hmac("50010517", "user2")
      refute a == Fints.identity_hmac("50010518", "user1")
    end

    test "credential_hmac is deterministic and depends on blz, login and pin" do
      a = Fints.credential_hmac("50010517", "user1", "1234")
      assert a == Fints.credential_hmac("50010517", "user1", "1234")
      refute a == Fints.credential_hmac("50010517", "user1", "9999")
    end

    test "identity_hmac and credential_hmac for the same identity are different hashes" do
      refute Fints.identity_hmac("50010517", "user1") ==
               Fints.credential_hmac("50010517", "user1", "1234")
    end

    test "both are lowercase-hex SHA-256 (64 chars) and never contain the raw pin" do
      h = Fints.credential_hmac("50010517", "user1", "supersecretpin")
      assert String.match?(h, ~r/^[0-9a-f]{64}$/)
      refute h =~ "supersecretpin"

      i = Fints.identity_hmac("50010517", "user1")
      assert String.match?(i, ~r/^[0-9a-f]{64}$/)
    end
  end

  describe "state storage round trip + reset (S3)" do
    test "get_state/2 is nil until saved, round-trips the saved value, then nil after reset" do
      assert Fints.get_state("blz1", "loginA") == nil
      assert :ok = Fints.save_state("blz1", "loginA", "abc123state")
      assert Fints.get_state("blz1", "loginA") == "abc123state"
      assert :ok = Fints.reset_state!("blz1", "loginA")
      assert Fints.get_state("blz1", "loginA") == nil
    end

    test "state is scoped per bank identity" do
      Fints.save_state("blz1", "loginA", "state-a")
      Fints.save_state("blz1", "loginB", "state-b")
      assert Fints.get_state("blz1", "loginA") == "state-a"
      assert Fints.get_state("blz1", "loginB") == "state-b"
    end

    test "saving a new state replaces the old one" do
      Fints.save_state("blz1", "loginA", "state-1")
      Fints.save_state("blz1", "loginA", "state-2")
      assert Fints.get_state("blz1", "loginA") == "state-2"
    end

    test "resetting a bank identity with no saved state is a no-op" do
      assert Fints.reset_state!("never-saved", "nobody") == :ok
      assert Fints.get_state("never-saved", "nobody") == nil
    end
  end

  describe "fetch/2 with a stubbed sidecar (S1/S4/S5)" do
    setup do
      keys = ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)
      original = Map.new(keys, &{&1, System.get_env(&1)})

      System.put_env("FINTS_BLZ", "50010517")
      System.put_env("FINTS_URL", "https://example.invalid/fints")
      System.put_env("FINTS_LOGIN", "test-login")
      System.put_env("FINTS_PIN", "1234")
      System.put_env("FINTS_PRODUCT_ID", "TEST")

      on_exit(fn ->
        Enum.each(original, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      :ok
    end

    test "a pin_error response latches, and a second fetch is refused without an HTTP call" do
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Fints, fn conn ->
        Agent.update(hits, &(&1 + 1))

        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{
          "detail" => %{"error" => "bank rejected the PIN or login", "pin_error" => true}
        })
      end)

      assert {:error, msg} = Fints.fetch(~D[2026-01-01])
      assert msg =~ "PIN"
      assert {:latched, "pin_error", %DateTime{}} = Fints.latch_status("50010517", "test-login", "1234")

      assert {:error, msg2} = Fints.fetch(~D[2026-01-01])
      assert msg2 =~ "check FINTS_LOGIN" or msg2 =~ "Check FINTS_LOGIN"
      # Refused before reaching the stub a second time.
      assert Agent.get(hits, & &1) == 1
    end

    test "a locked response also latches, with reason locked" do
      Req.Test.stub(Fints, fn conn ->
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{"detail" => %{"error" => "online banking is locked", "locked" => true}})
      end)

      assert {:error, _msg} = Fints.fetch(~D[2026-01-01])
      assert {:latched, "locked", %DateTime{}} = Fints.latch_status("50010517", "test-login", "1234")
    end

    test "the latch clears automatically when the PIN changes" do
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Fints, fn conn ->
        Agent.update(hits, &(&1 + 1))

        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{"detail" => %{"error" => "bad pin", "pin_error" => true}})
      end)

      assert {:error, _} = Fints.fetch(~D[2026-01-01])
      assert Agent.get(hits, & &1) == 1
      assert {:latched, _, _} = Fints.latch_status("50010517", "test-login", "1234")

      System.put_env("FINTS_PIN", "9999")

      # Different credentials — not blocked, so the sidecar is reached again.
      assert {:error, _} = Fints.fetch(~D[2026-01-01])
      assert Agent.get(hits, & &1) == 2
      assert Fints.latch_status("50010517", "test-login", "1234") == :clear
    end

    test "the latch also clears automatically when the login changes" do
      Req.Test.stub(Fints, fn conn ->
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{"detail" => %{"error" => "bad pin", "pin_error" => true}})
      end)

      assert {:error, _} = Fints.fetch(~D[2026-01-01])
      assert {:latched, _, _} = Fints.latch_status("50010517", "test-login", "1234")

      System.put_env("FINTS_LOGIN", "other-login")
      assert Fints.latch_status("50010517", "other-login", "1234") == :clear
    end

    test "clear_latch!/2 clears the latch by hand and leaves the stored state untouched" do
      Fints.save_state("50010517", "test-login", "some-state")

      Req.Test.stub(Fints, fn conn ->
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{"detail" => %{"error" => "bad pin", "pin_error" => true}})
      end)

      assert {:error, _} = Fints.fetch(~D[2026-01-01])
      assert {:latched, _, _} = Fints.latch_status("50010517", "test-login", "1234")

      assert Fints.clear_latch!("50010517", "test-login") == :ok
      assert Fints.latch_status("50010517", "test-login", "1234") == :clear
      assert Fints.get_state("50010517", "test-login") == "some-state"
    end

    test "a successful fetch saves the returned client_state" do
      Req.Test.stub(Fints, fn conn ->
        Req.Test.json(conn, %{"rows" => [], "accounts" => [], "client_state" => "fresh-state-blob"})
      end)

      assert {:ok, _result} = Fints.fetch(~D[2026-01-01])
      assert Fints.get_state("50010517", "test-login") == "fresh-state-blob"
    end

    test "a stored client_state is sent back to the sidecar on the next fetch" do
      Fints.save_state("50010517", "test-login", "prior-state-blob")
      {:ok, seen} = Agent.start_link(fn -> nil end)

      Req.Test.stub(Fints, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        Agent.update(seen, fn _ -> Jason.decode!(raw_body) end)
        Req.Test.json(conn, %{"rows" => [], "accounts" => []})
      end)

      assert {:ok, _} = Fints.fetch(~D[2026-01-01])
      assert Agent.get(seen, & &1)["client_state"] == "prior-state-blob"
    end

    test "a fetch with no stored state sends no client_state key" do
      {:ok, seen} = Agent.start_link(fn -> nil end)

      Req.Test.stub(Fints, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        Agent.update(seen, fn _ -> Jason.decode!(raw_body) end)
        Req.Test.json(conn, %{"rows" => [], "accounts" => []})
      end)

      assert {:ok, _} = Fints.fetch(~D[2026-01-01])
      refute Map.has_key?(Agent.get(seen, & &1), "client_state")
    end

    test "a second fetch while one is running is refused immediately (S5)" do
      parent = self()

      Req.Test.stub(Fints, fn conn ->
        send(parent, :sidecar_hit)

        receive do
          :proceed -> :ok
        after
          2000 -> :timeout
        end

        Req.Test.json(conn, %{"rows" => [], "accounts" => []})
      end)

      task = Task.async(fn -> Fints.fetch(~D[2026-01-01]) end)
      assert_receive :sidecar_hit, 1000

      assert Fints.fetch(~D[2026-01-01]) == {:error, "a bank fetch is already running"}

      send(task.pid, :proceed)
      assert {:ok, _result} = Task.await(task)
    end

    test "the lock is released after a fetch finishes, so the next one runs normally" do
      Req.Test.stub(Fints, fn conn ->
        Req.Test.json(conn, %{"rows" => [], "accounts" => []})
      end)

      assert {:ok, _} = Fints.fetch(~D[2026-01-01])
      assert {:ok, _} = Fints.fetch(~D[2026-01-01])
    end
  end
end
