defmodule Munin.Workers.UnderstandWorkerTest do
  use Munin.DataCase, async: false

  alias Munin.Documents.Document
  alias Munin.Workers.UnderstandWorker

  # LOCAL_LLM_URL unset means "no local provider" (per B3); with CLOUD_FALLBACK
  # also off, classify/1 -> call/4 resolves to {:retry, :no_local_provider}
  # without any HTTP request ever happening (no sidecar, no OpenRouter) — so
  # this exercises the real retry path end to end, deterministically, no
  # network required.
  setup do
    prev_local = System.get_env("LOCAL_LLM_URL")
    prev_cloud = System.get_env("CLOUD_FALLBACK")
    System.delete_env("LOCAL_LLM_URL")
    System.delete_env("CLOUD_FALLBACK")

    on_exit(fn ->
      if prev_local, do: System.put_env("LOCAL_LLM_URL", prev_local), else: System.delete_env("LOCAL_LLM_URL")
      if prev_cloud, do: System.put_env("CLOUD_FALLBACK", prev_cloud), else: System.delete_env("CLOUD_FALLBACK")
    end)

    doc =
      %Document{}
      |> Document.changeset(%{
        sha256: "sha-#{System.unique_integer([:positive])}",
        path: "/vault/fake.pdf",
        filename: "fake.pdf",
        mime: "application/pdf",
        body_text: "Rechnung Nr. 1 von Testfirma GmbH, Gesamtbetrag 100,00 EUR.",
        read_status: "done"
      })
      |> Repo.insert!()

    %{doc: doc}
  end

  test "local unreachable, cloud off -> Oban retries, no 'classification failed' is written", %{doc: doc} do
    assert {:snooze, _} =
             UnderstandWorker.perform(%Oban.Job{args: %{"id" => doc.id}})

    reloaded = Repo.get!(Document, doc.id)
    assert reloaded.meta == %{}
    refute Map.has_key?(reloaded.meta, "review_needed")
  end
end
