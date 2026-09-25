defmodule Munin.Money.Rule do
  @moduledoc """
  A learned money rule. Two kinds:

    * "classify"  — payee/purpose substring → {category, scope}. First hit
      (oldest first) wins. Created from the transactions page with one click;
      `Money.apply_rules!/0` replays them over existing lines.
    * "ignore_sub" — a normalized payee that the subscriptions radar should
      not list (rent, one-off recurring look-alikes, transfers).

  The built-in keyword list in Money stays as the fallback for fresh lines
  that no explicit rule covers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "money_rules" do
    field(:kind, :string, default: "classify")
    field(:pattern, :string)
    field(:category, :string)
    field(:scope, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:kind, :pattern, :category, :scope])
    |> validate_required([:kind, :pattern])
    |> validate_inclusion(:kind, ["classify", "ignore_sub"])
    |> validate_inclusion(:scope, ["business", "private"])
    |> update_change(:pattern, &String.trim/1)
    |> validate_length(:pattern, min: 2)
    |> unique_constraint([:kind, :pattern])
  end
end
