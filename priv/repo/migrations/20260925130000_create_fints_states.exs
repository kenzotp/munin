defmodule Munin.Repo.Migrations.CreateFintsStates do
  use Ecto.Migration

  def change do
    create table(:fints_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # HMAC-SHA256("<blz>|<login>", key: secret_key_base) — never the raw
      # login, so a credential change (different HMAC) starts a fresh row.
      add :identity_hmac, :string, null: false

      # base64 python-fints client_state (system_id, BPD/UPD, TAN
      # mechanism/medium) from the sidecar's deconstruct() — never the PIN.
      # Null until the first successful/partial fetch persists one.
      add :state, :text

      # Lockout latch (P3 pin_error/locked guard): HMAC-SHA256 of the exact
      # credentials that failed, so Fints.fetch can refuse a repeat attempt
      # without contacting the sidecar. Never the PIN or an unkeyed hash.
      add :latch_credential_hmac, :string
      add :latch_reason, :string
      add :latch_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fints_states, [:identity_hmac])
  end
end
