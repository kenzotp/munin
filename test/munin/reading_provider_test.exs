defmodule Munin.ReadingProviderTest do
  use ExUnit.Case, async: true

  alias Munin.Reading

  # resolve_provider/3 is the pure decision the OCR call sites make between
  # the local model and OpenRouter — exercised directly here (no network)
  # per B3: cloud is only ever consulted when cloud_fallback? is true, and a
  # transport-level local outage must come back as {:retry, _}, never
  # {:error, _}.

  test "local success short-circuits — cloud never consulted" do
    assert {:ok, "text"} =
             Reading.resolve_provider({:ok, "text"}, true, fn -> flunk("cloud must not run") end)
  end

  test "local unreachable + cloud off -> retry, cloud never called" do
    assert {:retry, :timeout} =
             Reading.resolve_provider({:unreachable, :timeout}, false, fn ->
               flunk("cloud must not run when CLOUD_FALLBACK is off")
             end)
  end

  test "local unreachable + cloud on -> falls back to cloud" do
    assert {:ok, "from cloud"} =
             Reading.resolve_provider({:unreachable, :timeout}, true, fn -> {:ok, "from cloud"} end)
  end

  test "local real error + cloud off -> error, cloud never called" do
    assert {:error, {:local_status, 400, %{}}} =
             Reading.resolve_provider({:error, {:local_status, 400, %{}}}, false, fn ->
               flunk("cloud must not run when CLOUD_FALLBACK is off")
             end)
  end

  test "local real error + cloud on but cloud also fails -> original local error" do
    assert {:error, {:local_status, 400, %{}}} =
             Reading.resolve_provider({:error, {:local_status, 400, %{}}}, true, fn ->
               {:error, :cloud_down}
             end)
  end
end
