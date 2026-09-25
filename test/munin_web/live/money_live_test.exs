defmodule MuninWeb.MoneyLiveTest do
  use MuninWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Munin.Money.Fints

  setup :register_and_log_in_user

  test "shows 'Never synced' with nothing recorded", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/money")
    assert html =~ "Never synced"
  end

  test "shows the ok outcome with the imported line count", %{conn: conn} do
    Fints.record_sync!(:manual, {:ok, %{imported: 12, duplicates: 1}})

    {:ok, _view, html} = live(conn, ~p"/money")
    assert html =~ "Bank synced "
    assert html =~ "12 new lines"
  end

  test "shows the failed outcome with the error message", %{conn: conn} do
    Fints.record_sync!(:manual, {:error, "sidecar unreachable"})

    {:ok, _view, html} = live(conn, ~p"/money")
    assert html =~ "Last sync failed "
    assert html =~ "sidecar unreachable"
  end
end
