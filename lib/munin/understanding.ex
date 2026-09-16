defmodule Munin.Understanding do
  @moduledoc """
  P2 understanding layer, stacked on the reading ladder: WHAT is this document,
  WHO is it from, and — for invoices/receipts — the money fields, with an
  arithmetic checksum that decides whether the extraction is trustworthy.

  Classification and extraction are two separate strict-JSON model calls (the
  classifier's schema is small and reliable; the extractor's is money-precise).
  Both run on an ordered OpenRouter model chain (CLASSIFY_MODELS env, free
  slugs rot — nied-mail's lesson).

  A failed checksum never blocks storage: the fields land with
  review_needed=true and the reason, and the review UI takes it from there.
  """
  require Logger

  @timeout 90_000
  @doc_types ~w(invoice receipt contract letter ticket statement other)

  def models do
    System.get_env(
      "CLASSIFY_MODELS",
      "nex-agi/nex-n2.5-mini:free,nex-agi/nex-n2.5-pro:free,google/gemma-4-26b-a4b-it:free"
    )
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Classify + extract for one document. Returns the updated Document."
  def understand(%Munin.Documents.Document{} = doc) do
    if doc.body_text in [nil, ""] do
      doc
    else
      meta = doc.meta || %{}

      case classify(doc) do
        {:ok, verdict} ->
          meta =
            Map.merge(meta, %{
              "doc_type" => verdict["doc_type"],
              "scope" => verdict["scope"],
              "vendor" => verdict["vendor"],
              "summary" => verdict["summary"]
            })

          meta =
            if verdict["doc_type"] in ["invoice", "receipt"] do
              Map.put(meta, "invoice", extract_invoice(doc))
            else
              meta
            end

          doc
          |> Munin.Documents.Document.changeset(%{
            title: verdict["title"] || doc.title,
            meta: meta
          })
          |> Munin.Repo.update!()

        {:error, reason} ->
          Logger.warning("[understand] classify failed for #{doc.id}: #{inspect(reason)}")
          doc
          |> Munin.Documents.Document.changeset(%{
            meta: Map.put(meta, "review_needed", true) |> Map.put("review_reason", "classification failed")
          })
          |> Munin.Repo.update!()
      end
    end
  end

  defp classify(doc) do
    schema = %{
      type: "object",
      properties: %{
        doc_type: %{type: "string", enum: @doc_types},
        scope: %{type: "string", enum: ["business", "private"]},
        vendor: %{type: "string"},
        title: %{type: "string"},
        summary: %{type: "string"}
      },
      required: [:doc_type, :scope, :vendor, :title, :summary],
      additionalProperties: false
    }

    prompt = """
    Classify this document. doc_type: invoice | receipt | contract | letter |
    ticket | statement | other. scope: business if it concerns the owner's own
    company work, private otherwise. vendor: the issuing company/person.
    title: a short human title (5-10 words). summary: one sentence.
    """

    call(doc, prompt, schema, 500)
  end

  @doc """
  Money extraction with the checksum gate. Returns the invoice map (never
  raises): a checksum mismatch sets review_needed inside the map instead.
  """
  def extract_invoice(doc) do
    schema = %{
      type: "object",
      properties: %{
        vendor: %{type: "string"},
        number: %{type: "string"},
        date: %{type: "string"},
        currency: %{type: "string"},
        total_gross: %{type: "number"},
        vat_amount: %{type: "number"},
        net_amount: %{type: "number"}
      },
      required: [:vendor, :number, :date, :currency, :total_gross, :vat_amount, :net_amount],
      additionalProperties: false
    }

    prompt = """
    Extract the invoice/receipt money fields from this document text. Rules:
    - total_gross = the TOTAL amount payable (incl. VAT).
    - vat_amount = the VAT shown; net_amount = total minus VAT.
    - German number formats: "1.234,56" means 1234.56.
    - If a field is genuinely absent use 0 (numeric) or "" (string).
    """

    case call(doc, prompt, schema, 700) do
      {:ok, fields} ->
        total = fields["total_gross"] + 0.0
        vat = fields["vat_amount"] + 0.0
        net = fields["net_amount"] + 0.0
        ok? = abs(net + vat - total) <= 0.02

        invoice = %{
          "vendor" => fields["vendor"],
          "number" => fields["number"],
          "date" => fields["date"],
          "currency" => fields["currency"],
          "total_gross" => total,
          "vat_amount" => vat,
          "net_amount" => net,
          "checksum_ok" => ok?
        }

        if ok? do
          invoice
        else
          Map.merge(invoice, %{
            "review_needed" => true,
            "review_reason" => "checksum failed: net + VAT ≠ total"
          })
        end

      {:error, reason} ->
        %{"review_needed" => true, "review_reason" => "extraction failed: #{inspect(reason)}"}
    end
  end

  defp call(doc, prompt, schema, max_tokens) do
    key = System.get_env("OPENROUTER_API_KEY", "")
    if key == "", do: throw({:error, :no_openrouter_key})

    content =
      """
      Filename: #{doc.filename}
      #{prompt}
      ---
      #{String.slice(doc.body_text || "", 0, 6000)}
      """

    last =
      Enum.reduce(models(), {:error, :no_models}, fn model, acc ->
        case call_model(model, key, content, schema, max_tokens) do
          {:ok, parsed} -> {:ok, parsed}
          error -> Logger.warning("[understand] model #{model} failed: #{inspect(error)}"); acc
        end
      end)

    last
  catch
    thrown -> thrown
  end

  defp call_model(model, key, content, schema, max_tokens) do
    case Req.post("https://openrouter.ai/api/v1/chat/completions",
           json: %{
             model: model,
             messages: [
               %{role: "system", content: "You are a precise document-understanding engine. Return ONLY the requested JSON."},
               %{role: "user", content: content}
             ],
             response_format: %{type: "json_schema", json_schema: %{name: "understanding", strict: true, schema: schema}},
             max_tokens: max_tokens,
             temperature: 0
           },
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: @timeout,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}}]}}} ->
        case Jason.decode(text || "{}") do
          {:ok, parsed} -> {:ok, parsed}
          error -> {:error, {:parse, error}}
        end

      {:ok, %{status: status, body: err}} ->
        {:error, {:http, status, err}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
