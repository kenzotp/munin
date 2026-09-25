defmodule MuninWeb.DocumentsLiveTest do
  use MuninWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Munin.Documents.Document
  alias Munin.Repo

  setup :register_and_log_in_user

  defp doc(filename, meta) do
    %Document{}
    |> Document.changeset(%{
      sha256: "sha-#{System.unique_integer([:positive])}",
      path: "/vault/#{filename}",
      filename: filename,
      mime: "application/pdf",
      read_status: "done",
      meta: meta
    })
    |> Repo.insert!()
  end

  # B2: meta["invoice"]["review_needed"] (checksum failed, or extraction
  # failed — same shape) must surface in the /documents?view=review queue and
  # get the row badge, even though it's not top-level meta["review_needed"].
  test "checksum-failed and extraction-failed invoices show up in the review view", %{conn: conn} do
    checksum_failed =
      doc("checksum-failed.pdf", %{
        "doc_type" => "invoice",
        "invoice" => %{"review_needed" => true, "review_reason" => "checksum failed: net + VAT ≠ total"}
      })

    extraction_failed =
      doc("extraction-failed.pdf", %{
        "doc_type" => "invoice",
        "invoice" => %{"review_needed" => true, "review_reason" => "extraction failed: timeout"}
      })

    clean = doc("clean.pdf", %{"doc_type" => "invoice", "invoice" => %{"review_needed" => false}})

    {:ok, lv, _html} = live(conn, ~p"/documents?#{%{q: "", view: "review"}}")
    html = render(lv)

    assert html =~ checksum_failed.filename
    assert html =~ extraction_failed.filename
    refute html =~ clean.filename

    # Same two show the "review" chip on the unfiltered list too.
    {:ok, lv_all, _html} = live(conn, ~p"/documents?#{%{q: "", view: "all"}}")
    all_html = render(lv_all)
    assert all_html =~ "review"
  end
end
