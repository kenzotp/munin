defmodule Munin.Understanding do
  @moduledoc """
  P2 understanding layer, stacked on the reading ladder: WHAT is this document,
  WHO is it from, and — for invoices/receipts — the money fields, with an
  arithmetic checksum that decides whether the extraction is trustworthy.

  Classification and extraction are two separate strict-JSON model calls (the
  classifier's schema is small and reliable; the extractor's is money-precise).
  Both run local-first: a local Ollama model (LOCAL_LLM_URL, LOCAL_LLM_MODEL)
  is tried first, always. An ordered OpenRouter model chain (CLASSIFY_MODELS
  env, free slugs rot — nied-mail's lesson) is only used when
  CLOUD_FALLBACK=true — with it off (the default, and the required setting
  for tax documents), no document text ever leaves the machine.

  A failed checksum never blocks storage: the fields land with
  review_needed=true and the reason, and the review UI takes it from there —
  at meta["invoice"]["review_needed"], read by the review views alongside the
  top-level meta["review_needed"] used for classification failures.
  """
  require Logger

  @timeout 90_000
  # A cold Ollama load (model swap) costs real time on the owner's host — a
  # live smoke test against gemma4:26b-a4b-it-qat measured ~293s just to load
  # before the first token, well past the "40-45s" ballpark, so this gives
  # real headroom (>= 180s per spec, wider in practice) before calling the
  # request a failure rather than a slow-but-fine cold start.
  @local_timeout 360_000
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

  @doc """
  Classify + extract for one document. Returns `{:ok, doc}` with the updated
  Document — including the case where classification or extraction failed
  outright and got a review flag — or `{:retry, reason}` when the local model
  was unreachable and cloud is off: nothing is written, the caller should
  retry later rather than record a failure.
  """
  def understand(%Munin.Documents.Document{} = doc) do
    if doc.body_text in [nil, ""] do
      {:ok, doc}
    else
      meta = doc.meta || %{}

      case classify(doc) do
        {:retry, reason} ->
          {:retry, reason}

        {:ok, verdict} ->
          meta =
            Map.merge(meta, %{
              "doc_type" => verdict["doc_type"],
              "scope" => verdict["scope"],
              "vendor" => verdict["vendor"],
              "summary" => verdict["summary"]
            })

          case with_invoice(doc, verdict, meta) do
            {:retry, reason} ->
              {:retry, reason}

            {:ok, meta} ->
              doc =
                doc
                |> Munin.Documents.Document.changeset(%{
                  title: verdict["title"] || doc.title,
                  meta: meta
                })
                |> Munin.Repo.update!()

              {:ok, doc}
          end

        {:error, reason} ->
          Logger.warning("[understand] classify failed for #{doc.id}: #{inspect(reason)}")

          doc =
            doc
            |> Munin.Documents.Document.changeset(%{
              meta: Map.put(meta, "review_needed", true) |> Map.put("review_reason", "classification failed")
            })
            |> Munin.Repo.update!()

          {:ok, doc}
      end
    end
  end

  defp with_invoice(doc, verdict, meta) do
    meta =
      Map.put(meta, "reminders", %{
        "due_date" => verdict["due_date"] || "",
        "warranty_months" => verdict["warranty_months"] || 0,
        "notice_days" => verdict["notice_days"] || 0
      })

    if verdict["doc_type"] in ["invoice", "receipt"] do
      case extract_invoice(doc) do
        {:retry, reason} -> {:retry, reason}
        {:ok, invoice} -> {:ok, Map.put(meta, "invoice", invoice)}
      end
    else
      {:ok, meta}
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
        summary: %{type: "string"},
        due_date: %{type: "string"},
        warranty_months: %{type: "integer"},
        notice_days: %{type: "integer"}
      },
      required: [:doc_type, :scope, :vendor, :title, :summary, :due_date, :warranty_months, :notice_days],
      additionalProperties: false
    }

    prompt = """
    Classify this document. doc_type: invoice | receipt | contract | letter |
    ticket | statement | other. scope: business if it concerns the owner's own
    company work, private otherwise. vendor: the issuing company/person.
    title: a short human title (5-10 words). summary: one sentence.
    Reminders: due_date = the payment deadline shown on an invoice/receipt as
    YYYY-MM-DD ("" if none). warranty_months = warranty length in months for
    receipts (0 if none). notice_days = the Kündigungsfrist of a contract in
    days (0 if none or unknown).
    """

    call(doc, prompt, schema, 500)
  end

  @doc """
  Money extraction with the checksum gate. Returns `{:ok, invoice_map}` — a
  checksum mismatch or an outright extraction failure sets review_needed
  inside the map instead of raising — or `{:retry, reason}` when the local
  model was unreachable and cloud is off.
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
      {:retry, reason} ->
        {:retry, reason}

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

        invoice =
          if ok? do
            invoice
          else
            Map.merge(invoice, %{
              "review_needed" => true,
              "review_reason" => "checksum failed: net + VAT ≠ total"
            })
          end

        {:ok, invoice}

      {:error, reason} ->
        {:ok, %{"review_needed" => true, "review_reason" => "extraction failed: #{inspect(reason)}"}}
    end
  end

  # -------------------------------------------------------------- providers

  defp local_llm_url, do: System.get_env("LOCAL_LLM_URL")
  defp local_llm_model, do: System.get_env("LOCAL_LLM_MODEL", "gemma4:26b-a4b-it-qat")
  defp cloud_fallback?, do: System.get_env("CLOUD_FALLBACK", "false") in ~w(true 1)

  # Given the local provider's outcome, decides whether to fall back to cloud
  # (only when `cloud_fallback?` is true) or ask for a retry. Pure aside from
  # the `cloud_fun` callback — kept separate from the HTTP calls, and public,
  # so provider selection is unit-testable without a network.
  @doc false
  def resolve_provider({:ok, _} = ok, _cloud_fallback?, _cloud_fun), do: ok

  def resolve_provider({:unreachable, reason}, cloud_fallback?, cloud_fun) do
    if cloud_fallback?, do: cloud_fun.(), else: {:retry, reason}
  end

  def resolve_provider({:error, _reason} = error, cloud_fallback?, cloud_fun) do
    if cloud_fallback? do
      case cloud_fun.() do
        {:ok, _} = ok -> ok
        _ -> error
      end
    else
      error
    end
  end

  defp call(doc, prompt, schema, max_tokens) do
    content =
      """
      Filename: #{doc.filename}
      #{prompt}
      ---
      #{String.slice(doc.body_text || "", 0, 6000)}
      """

    local_llm_url()
    |> local_call(content, schema)
    |> resolve_provider(cloud_fallback?(), fn -> cloud_call(content, schema, max_tokens) end)
  end

  # Ollama's native /api/chat, non-streaming, thinking off (gemma otherwise
  # answers inside the thinking field instead of content), structured output
  # via `format`.
  defp local_call(nil, _content, _schema), do: {:unreachable, :no_local_provider}

  defp local_call(url, content, schema) do
    body = %{
      model: local_llm_model(),
      stream: false,
      think: false,
      format: schema,
      options: %{temperature: 0},
      messages: [
        %{role: "system", content: "You are a precise document-understanding engine. Return ONLY the requested JSON."},
        %{role: "user", content: content}
      ]
    }

    case Req.post(Path.join(url, "/api/chat"), json: body, receive_timeout: @local_timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} ->
        case Jason.decode(text || "{}") do
          {:ok, parsed} -> {:ok, parsed}
          error -> {:error, {:parse, error}}
        end

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:unreachable, {:local_status, status, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:local_status, status, body}}

      {:error, reason} ->
        {:unreachable, {:local_transport, reason}}
    end
  end

  # Only reached when CLOUD_FALLBACK=true.
  defp cloud_call(content, schema, max_tokens) do
    key = System.get_env("OPENROUTER_API_KEY", "")
    if key == "" do
      {:error, :no_openrouter_key}
    else
      models()
      |> Enum.reduce({:error, :no_models}, fn model, acc ->
        case cloud_call_with(model, key, content, schema, max_tokens) do
          {:ok, parsed} -> {:ok, parsed}
          error -> Logger.warning("[understand] model #{model} failed: #{inspect(error)}"); acc
        end
      end)
    end
  end

  defp cloud_call_with(model, key, content, schema, max_tokens) do
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
