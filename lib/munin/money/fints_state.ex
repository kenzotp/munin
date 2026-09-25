defmodule Munin.Money.FintsState do
  @moduledoc """
  One row per bank identity (BLZ + login), keyed by an HMAC so the raw login
  is never stored. Holds two independent things that both belong to that
  identity — see Munin.Money.Fints:

    * `state` — the sidecar's persisted python-fints client_state (system_id,
      BPD/UPD, TAN mechanism/medium; never the PIN), so a fetch can skip the
      per-request bootstrap dialog. Cleared by "Reset bank session".

    * `latch_*` — a lockout latch set after the bank rejects the PIN/login or
      locks the account, so a repeat fetch with the same credentials is
      refused before it ever reaches the sidecar. Cleared automatically when
      the credentials change (different HMAC), or by hand via "I checked the
      PIN in the banking app".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "fints_states" do
    field :identity_hmac, :string
    field :state, :string
    field :latch_credential_hmac, :string
    field :latch_reason, :string
    field :latch_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(fints_state, attrs) do
    fints_state
    |> cast(attrs, [:identity_hmac, :state, :latch_credential_hmac, :latch_reason, :latch_at])
    |> validate_required([:identity_hmac])
    |> unique_constraint(:identity_hmac)
  end
end
