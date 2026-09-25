defmodule Munin.Reading do
  @moduledoc """
  The reading ladder, P1+P3 edition. Order is cheapest-first and deterministic
  before model, local-first before cloud:

    1. Sidecar /extract — embedded text layer (pypdf) or office/html/csv text
       (markitdown). If that yields real text, DONE — no model call at all.
    2. Sidecar /render — PDF pages → capped JPEGs (pymupdf).
    3. OCR over the page images: a local Ollama model (LOCAL_LLM_URL,
       LOCAL_LLM_MODEL) first, always. OpenRouter (OCR_MODELS) is only used
       when CLOUD_FALLBACK=true — with it off (the default), no page image
       ever leaves the machine.

  Originals are NEVER written to — results land in Document.body_text.
  Failures downgrade status instead of raising: "pending" (sidecar asleep, or
  the local model unreachable with cloud off — retried later), "failed"
  (reading genuinely broke), "empty" (nothing to read — a blank scan).
  """
  require Logger

  @vision_timeout 120_000
  # A cold Ollama load (model swap) costs real time on the owner's host — a
  # live smoke test against gemma4:26b-a4b-it-qat measured ~293s just to load
  # before the first token, well past the "40-45s" ballpark, so this gives
  # real headroom (>= 180s per spec, wider in practice) before calling the
  # request a failure rather than a slow-but-fine cold start.
  @local_timeout 360_000
  @min_text_chars 200

  def read(%Munin.Documents.Document{} = doc) do
    case extract(doc) do
      {:ok, text} when is_binary(text) and byte_size(text) >= @min_text_chars ->
        %{text: text, status: "done"}

      {:ok, _thin} ->
        case ocr(doc) do
          {:ok, text} -> %{text: text, status: "done"}
          {:empty, _} -> %{text: nil, status: "empty"}
          {:retry, reason} ->
            Logger.warning("[reading] local model unavailable for #{doc.id}, retrying later: #{inspect(reason)}")
            %{text: nil, status: "pending"}

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

  # -------------------------------------------------------------- providers

  defp local_llm_url, do: System.get_env("LOCAL_LLM_URL")
  defp local_llm_model, do: System.get_env("LOCAL_LLM_MODEL", "gemma4:26b-a4b-it-qat")
  defp cloud_fallback?, do: System.get_env("CLOUD_FALLBACK", "false") in ~w(true 1)

  defp ocr_page(jpeg_base64) do
    local_llm_url()
    |> local_ocr(jpeg_base64)
    |> resolve_provider(cloud_fallback?(), fn -> cloud_ocr_page(jpeg_base64) end)
  end

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

  # Ollama's native /api/chat, non-streaming, thinking off (gemma otherwise
  # answers inside the thinking field instead of content).
  defp local_ocr(nil, _jpeg_base64), do: {:unreachable, :no_local_provider}

  defp local_ocr(url, jpeg_base64) do
    body = %{
      model: local_llm_model(),
      stream: false,
      think: false,
      options: %{temperature: 0},
      messages: [
        %{
          role: "user",
          content:
            "Transcribe ALL text on this document page exactly as written, preserving " <>
              "layout order. Output ONLY the transcription — no commentary, no markdown.",
          images: [jpeg_base64]
        }
      ]
    }

    case Req.post(Path.join(url, "/api/chat"), json: body, receive_timeout: @local_timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} ->
        {:ok, String.trim(text || "")}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:unreachable, {:local_status, status, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:local_status, status, body}}

      {:error, reason} ->
        {:unreachable, {:local_transport, reason}}
    end
  end

  # Ordered fallback chain (nied-mail's lesson: free slugs rot in days). The
  # first entry is the primary; every entry must be vision-capable. Only
  # reached when CLOUD_FALLBACK=true.
  defp models do
    System.get_env(
      "OCR_MODELS",
      "google/gemma-4-26b-a4b-it:free,inclusionai/ling-3.0-flash-vl:free,nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"
    )
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp cloud_ocr_page(jpeg_base64) do
    key = System.get_env("OPENROUTER_API_KEY", "")
    if key == "" do
      {:error, :no_openrouter_key}
    else
      errors =
        models()
        |> Enum.reduce(:last_resort, fn
          model, acc when acc == :last_resort or elem(acc, 0) == :error ->
            case cloud_ocr_page_with(model, key, jpeg_base64) do
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

  defp cloud_ocr_page_with(model, key, jpeg_base64) do
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
