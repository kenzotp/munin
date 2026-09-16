# One-off: register (or fetch) a user, confirm them, and mint a magic-link
# login URL. Run in a builder container on the compose network:
#   MIX_ENV=prod mix run priv/repo/seed_user.exs
email = System.get_env("SEED_EMAIL", "mika@nied.cc")

{:ok, _started} = Application.ensure_all_started(:munin)

user =
  case Munin.Accounts.get_user_by_email(email) do
    nil ->
      {:ok, u} = Munin.Accounts.register_user(%{email: email})
      u

    u ->
      u
  end

Munin.Repo.update!(
  Ecto.Changeset.change(user, confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
)

{encoded_token, user_token} = Munin.Accounts.UserToken.build_email_token(user, "login")
Munin.Repo.insert!(user_token)
IO.puts("LOGIN_URL=https://munin.nied.cc/users/log-in/" <> encoded_token)
