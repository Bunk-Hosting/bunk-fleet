defmodule ControlPlane.Mailer do
  @moduledoc """
  Outbound transactional mail (Swoosh). The adapter is configured per-env: SMTP in
  production (`config/runtime.exs`, no-op with a boot-time warning if `SMTP_HOST`
  is unset), an in-memory local mailbox in dev (`/dev/mailbox`), and a capturing
  test adapter in test (`assert_email_sent/1`). See `ControlPlane.Notifier` for
  what actually gets sent.
  """
  use Swoosh.Mailer, otp_app: :control_plane
end
