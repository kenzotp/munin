defmodule Munin.UnderstandingProviderTest do
  use ExUnit.Case, async: true

  alias Munin.Understanding

  # Same pure decision as Munin.Reading.resolve_provider/3, mirrored here for
  # classify/extract: cloud only runs when cloud_fallback? is true, and a
  # local outage must never be reported as a plain error.

  test "local success short-circuits — cloud never consulted" do
    assert {:ok, %{"doc_type" => "invoice"}} =
             Understanding.resolve_provider({:ok, %{"doc_type" => "invoice"}}, true, fn ->
               flunk("cloud must not run")
             end)
  end

  test "local unreachable + cloud off -> retry, cloud never called" do
    assert {:retry, :no_local_provider} =
             Understanding.resolve_provider({:unreachable, :no_local_provider}, false, fn ->
               flunk("cloud must not run when CLOUD_FALLBACK is off")
             end)
  end

  test "local unreachable + cloud on -> falls back to cloud" do
    assert {:ok, %{"doc_type" => "receipt"}} =
             Understanding.resolve_provider({:unreachable, :timeout}, true, fn ->
               {:ok, %{"doc_type" => "receipt"}}
             end)
  end

  test "local real error + cloud off -> error, cloud never called" do
    assert {:error, {:local_status, 400, %{}}} =
             Understanding.resolve_provider({:error, {:local_status, 400, %{}}}, false, fn ->
               flunk("cloud must not run when CLOUD_FALLBACK is off")
             end)
  end
end
