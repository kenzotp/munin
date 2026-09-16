defmodule Munin.Mailer do
  @moduledoc """
  P1 stub mailer: builds real Swoosh emails (the auth flow's magic links) but
  the adapter is the Test one, so everything is logged and nothing sends.
  When the instance gets SMTP (mailbox.org is right there), swap the adapter
  in config — the auth flow then starts delivering real magic links without
  any other change.
  """
  use Swoosh.Mailer, otp_app: :munin
end
