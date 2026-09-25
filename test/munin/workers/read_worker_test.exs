defmodule Munin.Workers.ReadWorkerTest do
  use Munin.DataCase, async: false

  alias Munin.Documents.Document
  alias Munin.Workers.ReadWorker

  # Point VISION_URL at a port nothing listens on so the sidecar call fails
  # fast and deterministically (Reading.extract/1 -> {:sidecar_down, _}),
  # landing read_status "pending" — the case ReadWorker must snooze instead
  # of silently finishing (previously it always returned :ok, so a pending
  # document was never retried automatically).
  setup do
    prev = System.get_env("VISION_URL")
    System.put_env("VISION_URL", "http://127.0.0.1:1")
    on_exit(fn -> if prev, do: System.put_env("VISION_URL", prev), else: System.delete_env("VISION_URL") end)

    doc =
      %Document{}
      |> Document.changeset(%{
        sha256: "sha-#{System.unique_integer([:positive])}",
        path: "/vault/fake.pdf",
        filename: "fake.pdf",
        mime: "application/pdf",
        read_status: "pending"
      })
      |> Repo.insert!()

    %{doc: doc}
  end

  test "sidecar down -> read_status stays pending and the job snoozes (real retry)", %{doc: doc} do
    assert {:snooze, seconds} = ReadWorker.perform(%Oban.Job{args: %{"id" => doc.id}})
    assert is_integer(seconds) and seconds > 0

    reloaded = Repo.get!(Document, doc.id)
    assert reloaded.read_status == "pending"
  end
end
