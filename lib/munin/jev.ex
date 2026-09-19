defmodule Munin.Jev do
  @moduledoc """
  Jev (TypeSafe System One) second opinion for invoice↔bank-line matches.

  The deterministic engine (vendor tokens + exact amount + date window) stays
  the source of candidates; Jev only answers one yes/no question per
  candidate pair — "is this bank line the payment of this invoice" — with a
  calibrated noul score. Matches it bless are auto-confirmed, matches it
  doubt stay in the existing review queue on /money/tx. With no key
  configured (or any error) the matcher keeps its legacy behaviour exactly.
  """

  @url "https://api.typesafe.ai/v1/systemone"

  def api_key, do: Application.get_env(:munin, :typesafe_api_key, "")
  def model, do: Application.get_env(:munin, :jev_model, "jev-latest")
  @doc "Noul above which an auto-match may proceed without a human."
  def auto_threshold, do: Application.get_env(:munin, :jev_match_threshold, 0.85)

  def enabled?, do: String.trim(api_key() || "") != ""

  @doc """
  One Jev call for a candidate pair.

  Returns `{:ok, noul}` (0.0–1.0), `:skip` when disabled (caller keeps legacy
  behaviour), or `{:error, reason}` (caller also keeps legacy behaviour).
  """
  def invoice_matches_line?(%Munin.Documents.Document{} = doc, %Munin.Money.Transaction{} = line) do
    if enabled?() do
      with :ok <- guard_url(),
           {:ok, 200, body} <- post(state(doc, line)),
           {:ok, decoded} <- Jason.decode(body),
           n when is_number(n) <- get_in(decoded, ["answers", "matches", "noul"]) do
        {:ok, n / 1.0}
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_response, other}}
      end
    else
      :skip
    end
  end

  # The API key travels in this request: https on a public host only.
  defp guard_url do
    uri = URI.parse(@url)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      case :inet.getaddr(String.to_charlist(uri.host), :inet) do
        {:ok, addr} ->
          if private?(addr) do
            {:error, {:refused_host, :inet.ntoa(addr)}}
          else
            :ok
          end

        {:error, reason} ->
          {:error, {:resolve, uri.host, reason}}
      end
    else
      {:error, :bad_url}
    end
  end

  defp private?(addr) do
    case :inet.ntoa(addr) do
      {:ok, text} ->
        s = to_string(text)
        String.starts_with?(s, "10.") or String.starts_with?(s, "127.") or
          String.starts_with?(s, "192.168.") or String.starts_with?(s, "169.254.") or
          s == "0.0.0.0" or String.starts_with?(s, "172.16.") or
          Enum.any?(17..31, fn o -> String.starts_with?(s, "172.#{o}.") end)

      _ ->
        true
    end
  end

  defp state(doc, line) do
    inv = get_in(doc.meta, ["invoice"]) || %{}

    """
    Does this bank transaction correspond to the payment of this invoice?

    Invoice:
    vendor: #{inv["vendor"]}
    number: #{inv["number"]}
    date: #{inv["date"]}
    total gross: #{inv["total_gross"]}

    Bank transaction:
    booked at: #{line.booked_at}
    amount cents: #{line.amount_cents}
    currency: #{line.currency}
    payer: #{line.payer}
    description: #{line.description}
    """
  end

  defp post(state) do
    {:ok, body} =
      Jason.encode(%{
        model: model(),
        state: state,
        questions: %{
          "matches" => %{
            "type" => "noul",
            "instructions" =>
              "The bank transaction is the payment of this exact invoice: same vendor, the amount equals the invoice total, and the date is consistent."
          }
        }
      })

    headers = [
      {"authorization", "Bearer " <> String.trim(api_key())},
      {"content-type", "application/json"}
    ]

    request = {String.to_charlist(@url), headers, ~c"application/json", body}

    http_options = [
      ssl: ssl_options(),
      timeout: 15_000,
      connect_timeout: 10_000,
      autoredirect: true
    ]

    :inets.start()
    :ssl.start()

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_http, status, _}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, {:httpc, reason}}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
