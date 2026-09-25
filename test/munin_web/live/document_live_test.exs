defmodule MuninWeb.DocumentLiveTest do
  use MuninWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Munin.Documents.Document
  alias Munin.Repo

  setup :register_and_log_in_user

  defp invoice_doc(meta) do
    %Document{}
    |> Document.changeset(%{
      sha256: "sha-#{System.unique_integer([:positive])}",
      path: "/vault/fake.pdf",
      filename: "fake.pdf",
      mime: "application/pdf",
      body_text: "Rechnung",
      read_status: "done",
      meta: meta
    })
    |> Repo.insert!()
  end

  # B1: German-or-plain amount parsing on save, via Munin.Money.parse_euro/1.
  describe "German amounts on save" do
    setup do
      %{doc: invoice_doc(%{"doc_type" => "invoice"})}
    end

    for {input, expected} <- [
          {"1.234,56", 1234.56},
          {"1234,56", 1234.56},
          {"1234.56", 1234.56},
          {" 12,00 € ", 12.0}
        ] do
      test "\"#{input}\" -> #{expected}", %{conn: conn, doc: doc} do
        {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

        render_submit(lv, "save", %{
          "title" => "T",
          "vendor" => "V",
          "doc_type" => "invoice",
          "scope" => "business",
          "number" => "1",
          "date" => "2026-01-01",
          "currency" => "EUR",
          "net_amount" => unquote(input),
          "vat_amount" => "0",
          "total_gross" => unquote(input)
        })

        reloaded = Repo.get!(Document, doc.id)
        assert reloaded.meta["invoice"]["total_gross"] == unquote(expected)
        assert reloaded.meta["invoice"]["net_amount"] == unquote(expected)
      end
    end

    test "empty amount keeps the historical 0.0 behaviour", %{conn: conn, doc: doc} do
      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      render_submit(lv, "save", %{
        "title" => "T",
        "vendor" => "V",
        "doc_type" => "invoice",
        "scope" => "business",
        "number" => "",
        "date" => "",
        "currency" => "EUR",
        "net_amount" => "",
        "vat_amount" => "",
        "total_gross" => ""
      })

      reloaded = Repo.get!(Document, doc.id)
      assert reloaded.meta["invoice"]["total_gross"] == 0.0
    end

    test "garbage input does not crash, does not save, and shows an error", %{conn: conn} do
      doc =
        invoice_doc(%{
          "doc_type" => "invoice",
          "invoice" => %{"vendor" => "Original", "total_gross" => 42.0, "vat_amount" => 2.0, "net_amount" => 40.0}
        })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      html =
        render_submit(lv, "save", %{
          "title" => "T",
          "vendor" => "V",
          "doc_type" => "invoice",
          "scope" => "business",
          "number" => "1",
          "date" => "2026-01-01",
          "currency" => "EUR",
          "net_amount" => "0",
          "vat_amount" => "0",
          "total_gross" => "abc"
        })

      # The LiveView is still alive and rendering (no crash).
      assert Process.alive?(lv.pid)
      assert html =~ "Could not save"

      # Nothing was persisted — the original invoice data is untouched.
      reloaded = Repo.get!(Document, doc.id)
      assert reloaded.meta["invoice"]["total_gross"] == 42.0
      assert reloaded.meta["invoice"]["vendor"] == "Original"
    end
  end

  # B2: a nested meta["invoice"]["review_needed"] flag must surface on the
  # page, and confirming (save) must clear it.
  describe "review badge and confirm" do
    test "checksum-failed invoice shows the review badge", %{conn: conn} do
      doc =
        invoice_doc(%{
          "doc_type" => "invoice",
          "invoice" => %{
            "vendor" => "V",
            "total_gross" => 100.0,
            "vat_amount" => 5.0,
            "net_amount" => 90.0,
            "checksum_ok" => false,
            "review_needed" => true,
            "review_reason" => "checksum failed: net + VAT ≠ total"
          }
        })

      {:ok, _lv, html} = live(conn, ~p"/documents/#{doc.id}")
      assert html =~ "needs review"
      assert html =~ "checksum failed"
    end

    test "confirming clears the nested review flag", %{conn: conn} do
      doc =
        invoice_doc(%{
          "doc_type" => "invoice",
          "invoice" => %{
            "vendor" => "V",
            "total_gross" => 100.0,
            "vat_amount" => 5.0,
            "net_amount" => 90.0,
            "checksum_ok" => false,
            "review_needed" => true,
            "review_reason" => "checksum failed: net + VAT ≠ total"
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      html =
        render_submit(lv, "save", %{
          "title" => "T",
          "vendor" => "V",
          "doc_type" => "invoice",
          "scope" => "business",
          "number" => "1",
          "date" => "2026-01-01",
          "currency" => "EUR",
          "net_amount" => "90,00",
          "vat_amount" => "10,00",
          "total_gross" => "100,00"
        })

      refute html =~ "needs review"

      reloaded = Repo.get!(Document, doc.id)
      refute reloaded.meta["invoice"]["review_needed"]
      refute Map.has_key?(reloaded.meta, "review_needed")
    end
  end
end
