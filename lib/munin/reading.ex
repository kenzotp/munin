defmodule Munin.Reading do
  @moduledoc """
  The reading ladder, P1 edition. Order is cheapest-first and deterministic
  before model:

    1. Sidecar /extract — embedded text layer (pypdf) or office/html/csv text
       (markitdown). If that yields real text, DONE — no model call at all.
    2. Sidecar /render — PDF pages → capped JPEGs (pymupdf).
    3. OpenRouter VLM (OCR_MODEL env) over the page images, one call per page,
       collected into the body text.

  Originals are NEVER written to — results land in Document.body_text.
  Failures downgrade status instead of raising: "pending" (sidecar asleep —
  retried later), "failed" (reading genuinely broke), "empty" (nothing to
  read — a blank scan).
  """
  require Logger

  @vision_timeout 120_000
  @min_text_chars 200

  def read(%Munin.Documents.Document{} = doc) do
    case extract(doc) do
      {:ok, text} when is_binary(text) and byte_size(text) >= @min_text_chars ->
        %{text: text, status: "done"}

      {:ok, _thin} ->
        case ocr(doc) do
          {:ok, text} -> %{text: text, status: "done"}
          {:empty, _} -> %{text: nil, status: "empty"}
          {:error, reason} ->
            Logger.warning("[reading] OCR failed for #{doc.id}: #{inspect(reason)}")
            %{text: nil, status: "failed"}
        end

      {:sidecar_down, reason} ->
        Logger.warning("[reading] sidecar down for #{doc.id}: #{inspect(reason)}")
        %{text: nil, status: "pending"}

      {:error, reason} ->
        Logger.warning("[reading] extract failed for #{doc.id}: #{inspect(reason)}")
        %{text: nil, status: "failed"}
    end
  end

  defp vision_url(path), do: Path.join(vision_base(), path)
  defp vision_base, do: System.get_env("VISION_URL", "http://munin_vision:8100")

  defp extract(%{path: path}) do
    case Req.post(vision_url("/extract"), json: %{path: path}, receive_timeout: @vision_timeout) do
      {:ok, %{status: 200, body: %{"text" => text}}} -> {:ok, text}
      {:ok, %{status: status, body: body}} -> {:error, {:sidecar_status, status, body}}
      {:error, reason} -> {:sidecar_down, reason}
    end
  end

  @doc """
  VLM OCR over rendered pages. Only meaningful for PDFs; anything else that
  reached this point has no text and no pages, so it reports empty.
  """
  def ocr(%{mime: mime, path: path}) do
    if mime && String.contains?(mime, "pdf") do
      with {:ok, %{status: 200, body: %{"pages" => pages}}} <-
             Req.post(vision_url("/render"), json: %{path: path}, receive_timeout: @vision_timeout) do
        pages
        |> Enum.sort_by(& &1["n"])
        |> Enum.reduce_while({:ok, []}, fn page, {:ok, acc} ->
          case ocr_page(page["jpeg_base64"]) do
            {:ok, text} -> {:cont, {:ok, [text | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, texts} ->
            joined = texts |> Enum.reverse() |> Enum.join("\n\n") |> String.trim()
            if joined == "", do: {:empty, :no_text}, else: {:ok, joined}

          error ->
            error
        end
      else
        {:ok, %{status: status, body: body}} -> {:error, {:sidecar_status, status, body}}
        {:error, reason} -> {:sidecar_down, reason}
      end
    else
      {:empty, :not_a_pdf}
    end
  end

  # Ordered fallback chain (nied-mail's lesson: free slugs rot in days). The
  # first entry is the primary; every entry must be vision-capable.
  defp models do
    System.get_env(
      "OCR_MODELS",
      "google/gemma-4-26b-a4b-it:free,inclusionai/ling-3.0-flash-vl:free,nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"
    )
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp ocr_page(jpeg_base64) do
    key = System.get_env("OPENROUTER_API_KEY", "")
    if key == "" do
      {:error, :no_openrouter_key}
    else
      errors =
        models()
        |> Enum.reduce(:last_resort, fn
          model, acc when acc == :last_resort or elem(acc, 0) == :error ->
            case ocr_page_with(model, key, jpeg_base64) do
              {:ok, _} = ok -> ok
              error -> {:error, {model, error}}
            end
          _, ok -> ok
        end)

      case errors do
        {:ok, _} = ok -> ok
        {:error, {model, {:openrouter, status, err}}} ->
          Logger.warning("[reading] OCR model #{model} failed: #{status} #{inspect(err)}")
          {:error, {:openrouter, status, err}}
        other -> other
      end
    end
  end

  defp ocr_page_with(model, key, jpeg_base64) do
    body = %{
      model: model,
      messages: [
        %{
          role: "user",
          content: [
            %{
              type: "text",
              text:
                "Transcribe ALL text on this document page exactly as written, preserving " <>
                  "layout order. Output ONLY the transcription — no commentary, no markdown."
            },
            %{type: "image_url", image_url: %{url: "data:image/jpeg;base64," <> jpeg_base64}}
          ]
        }
      ],
      temperature: 0
    }

    case Req.post("https://openrouter.ai/api/v1/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: @vision_timeout,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}}]}}} ->
        {:ok, String.trim(text || "")}

      {:ok, %{status: status, body: err}} ->
        {:error, {:openrouter, status, err}}

      {:error, reason} ->
        {:error, {:openrouter, reason}}
    end
  end
end
