defmodule Munin.Workers.BankSyncWorkerTest do
  use Munin.DataCase, async: false

  alias Munin.Money.Fints
  alias Munin.Workers.BankSyncWorker

  @fints_keys ~w(FINTS_BLZ FINTS_URL FINTS_LOGIN FINTS_PIN FINTS_PRODUCT_ID)

  defp put_fints_env do
    System.put_env("FINTS_BLZ", "50010517")
    System.put_env("FINTS_URL", "https://example.invalid/fints")
    System.put_env("FINTS_LOGIN", "test-login")
    System.put_env("FINTS_PIN", "1234")
    System.put_env("FINTS_PRODUCT_ID", "TEST")
  end

  defp with_env_restore(keys, fun) do
    original = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    fun.()
  end

  describe "perform/1 when FinTS is not configured" do
    setup do
      with_env_restore(@fints_keys, fn -> Enum.each(@fints_keys, &System.delete_env/1) end)
      :ok
    end

    test "no-ops and never records a sync attempt" do
      assert :ok = BankSyncWorker.perform(%Oban.Job{args: %{}})
      assert Fints.last_sync() == nil
    end
  end

  describe "perform/1 when FinTS is configured" do
    setup do
      with_env_restore(@fints_keys, &put_fints_env/0)
      :ok
    end

    test "fetches the last 14 days in Europe/Berlin and records an ok outcome" do
      {:ok, seen} = Agent.start_link(fn -> nil end)

      Req.Test.stub(Fints, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        Agent.update(seen, fn _ -> Jason.decode!(raw_body) end)

        Req.Test.json(conn, %{
          "rows" => [],
          "accounts" => [],
          "client_state" => nil
        })
      end)

      assert :ok = BankSyncWorker.perform(%Oban.Job{args: %{}})

      expected_start = Date.add(BankSyncWorker.today(), -14)
      assert Agent.get(seen, & &1)["start"] == Date.to_iso8601(expected_start)

      sync = Fints.last_sync()
      assert sync.status == "ok"
      assert sync.trigger == "scheduled"
      assert sync.imported == 0
      assert sync.duplicates == 0
    end

    test "a latched identity refuses without any HTTP call, and records the error" do
      Req.Test.stub(Fints, fn conn ->
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{"detail" => %{"error" => "bad pin", "pin_error" => true}})
      end)

      # First attempt latches the credentials.
      assert :ok = BankSyncWorker.perform(%Oban.Job{args: %{}})
      assert %{status: "error"} = Fints.last_sync()

      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Fints, fn conn ->
        Agent.update(hits, &(&1 + 1))
        Req.Test.json(conn, %{"rows" => [], "accounts" => []})
      end)

      # Second attempt: the job still finishes cleanly (no crash, no retry),
      # but the latch refuses it before the sidecar is ever contacted.
      assert :ok = BankSyncWorker.perform(%Oban.Job{args: %{}})
      assert Agent.get(hits, & &1) == 0

      sync = Fints.last_sync()
      assert sync.status == "error"
      assert sync.trigger == "scheduled"
      assert sync.error_message =~ "PIN" or sync.error_message =~ "check FINTS_LOGIN" or
               sync.error_message =~ "Check FINTS_LOGIN"
    end
  end

  describe "cron_plugin/3" do
    test "builds the Cron plugin when configured and not switched off" do
      assert {Oban.Plugins.Cron, opts} = BankSyncWorker.cron_plugin(true, nil, nil)
      assert opts[:timezone] == "Europe/Berlin"
      assert opts[:crontab] == [{"0 5 * * *", BankSyncWorker}]
    end

    test "honors a BANK_SYNC_CRON override" do
      assert {Oban.Plugins.Cron, opts} = BankSyncWorker.cron_plugin(true, nil, "30 4 * * *")
      assert opts[:crontab] == [{"30 4 * * *", BankSyncWorker}]
    end

    test "is left out (nil) when BANK_SYNC=off" do
      assert BankSyncWorker.cron_plugin(true, "off", nil) == nil
    end

    test "is left out (nil) when FinTS isn't configured" do
      assert BankSyncWorker.cron_plugin(false, nil, nil) == nil
    end
  end

  describe "status_line/0" do
    setup do
      with_env_restore(@fints_keys, fn -> Enum.each(@fints_keys, &System.delete_env/1) end)
      with_env_restore(["BANK_SYNC"], fn -> System.delete_env("BANK_SYNC") end)
      :ok
    end

    test "reads 'Never synced' with nothing recorded" do
      assert BankSyncWorker.status_line() == "Never synced"
    end

    test "renders an ok outcome with the German date and new-line count" do
      Fints.record_sync!(:manual, {:ok, %{imported: 12, duplicates: 3, accounts: [], errors: []}})

      line = BankSyncWorker.status_line()
      assert line =~ "Bank synced "
      assert line =~ "— 12 new lines"
    end

    test "renders an error outcome with just the time and the message" do
      Fints.record_sync!(:manual, {:error, "sidecar unreachable"})

      line = BankSyncWorker.status_line()
      assert line =~ "Last sync failed "
      assert line =~ "sidecar unreachable"
      refute line =~ "new line"
    end
  end
end
