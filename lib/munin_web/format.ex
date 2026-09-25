defmodule MuninWeb.Format do
  @moduledoc """
  German display formats for money and dates: `1.234,56 €`, `25.09.2026`.
  Import into LiveViews; replaces the ad-hoc `money/1` helpers.
  """

  def money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    euros = cents |> abs() |> div(100) |> Integer.to_string() |> group_thousands()
    frac = cents |> abs() |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}#{euros},#{frac} €"
  end

  def date(%Date{} = d),
    do: :io_lib.format("~2..0B.~2..0B.~4..0B", [d.day, d.month, d.year]) |> IO.iodata_to_binary()

  defp group_thousands(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
    |> String.replace(",", ".")
  end
end
