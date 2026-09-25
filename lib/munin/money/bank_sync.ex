defmodule Munin.Money.BankSync do
  @moduledoc """
  One row per recorded bank-sync attempt (scheduled or manual) — an audit
  trail, not a singleton: `Munin.Money.Fints.last_sync/0` reads the most
  recent row. Written only by `Munin.Money.Fints.record_sync!/2`; never
  affects `fetch/2` itself.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bank_syncs" do
    field :attempted_at, :utc_datetime
    field :trigger, :string
    field :status, :string
    field :imported, :integer
    field :duplicates, :integer
    field :error_message, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(bank_sync, attrs) do
    bank_sync
    |> cast(attrs, [:attempted_at, :trigger, :status, :imported, :duplicates, :error_message])
    |> validate_required([:attempted_at, :trigger, :status])
    |> validate_inclusion(:trigger, ~w(scheduled manual))
    |> validate_inclusion(:status, ~w(ok error))
  end
end
