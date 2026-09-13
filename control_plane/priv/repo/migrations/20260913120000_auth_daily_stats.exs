defmodule ControlPlane.Repo.Migrations.AuthDailyStats do
  use Ecto.Migration

  # Counts per day, and nothing else. No user id, no email, no IP, no per-attempt
  # row — so there is no personal data here to protect, delete on request, or
  # explain in a privacy policy. That is the whole design: an operator needs to
  # see "were there four hundred failed logins last night", and that question is
  # answerable without recording who any of them were.
  def change do
    create table(:auth_daily_stats, primary_key: false) do
      add :day, :date, primary_key: true
      add :successes, :integer, null: false, default: 0
      add :failures, :integer, null: false, default: 0
      add :registrations, :integer, null: false, default: 0
      add :captcha_refusals, :integer, null: false, default: 0
    end
  end
end
