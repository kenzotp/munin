defmodule Munin.Money.Transaction do
  @moduledoc """
  One bank line. Real money arrives in P3 via FinTS/Enable Banking; today the
  table is fed by CSV import (real Sparkasse exports work) and the simulator.
  Dedupe is the Firefly trick: a content hash per account, unique index —
  re-importing the same CSV can never double-book.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transactions" do
    field :account, :string
    field :external_id, :string
    field :hash, :string
    field :booked_at, :date
    field :amount_cents, :integer
    field :currency, :string, default: "EUR"
    field :payer, :string
    field :description, :string
    field :iban, :string
    field :category, :string
    field :scope, :string
    field :source, :string, default: "csv"
    field :matched_document_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:account, :external_id, :hash, :booked_at, :amount_cents, :currency, :payer, :description, :iban, :category, :scope, :source, :matched_document_id])
    |> validate_required([:account, :hash, :booked_at, :amount_cents])
    |> unique_constraint([:account, :hash])
  end
end
