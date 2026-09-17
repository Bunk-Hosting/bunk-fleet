defmodule ControlPlane.Fixtures do
  @moduledoc """
  Shared entities for tests that need a *realistic* account to work with.

  The one fixture here exists because of a subtlety that bit three separate test
  files into writing the same five lines: the signup bonus is granted when the
  email address is confirmed (`ControlPlane.Accounts.confirm_user/1`), not when
  the account is created. A user straight out of `register_user/1` therefore has
  an empty wallet, so any test about credits, top-ups or paid provisioning that
  registers a user and stops there is silently testing a customer who cannot
  exist in production. Going through the real confirmation flow — rather than
  stamping `confirmed_at` or inserting a ledger entry by hand — also keeps these
  tests honest about that flow: if confirmation ever stops granting the bonus,
  they fail here instead of quietly drifting.

  Not a `CaseTemplate`: `ControlPlane.DataCase` and `ControlPlaneWeb.ConnCase`
  own the sandbox/`conn` setup, and a plain module with plain functions composes
  with both without either having to know about it. Tests opt in explicitly:

      import ControlPlane.Fixtures
  """

  alias ControlPlane.Accounts

  # Long enough for the 12-character minimum in User.registration_changeset/2;
  # tests that log in with a password pass their own.
  # Obviously fake, and deliberately so: this used to be a real credential from
  # the operator's own estate with a suffix, committed across seven files and
  # recoverable from the git history. A fixture password must be recognisable as
  # a fixture at a glance.
  @default_password "test-only-password-4f2b9c1e"

  @doc """
  Registers a user, confirms their email address, and returns the confirmed
  `%User{}` — i.e. an account holding the signup bonus, the state every paying
  customer is actually in.

  Takes an email string for the common case, or a map/keyword of registration
  attributes (`:email`, `:password`, `:name`, …) when a test needs a specific
  password or name. A unique email is generated when none is given.

      user = confirmed_user_fixture("billing@bunk.test")
      user = confirmed_user_fixture(%{email: "op@bunk.test", password: "kies-iets-langs", name: "Op"})

  Raises on any failure along the way: a fixture that half-succeeds would make
  the real assertions fail somewhere far less obvious.
  """
  def confirmed_user_fixture(attrs \\ %{})

  def confirmed_user_fixture(email) when is_binary(email),
    do: confirmed_user_fixture(%{email: email})

  def confirmed_user_fixture(attrs) do
    attrs = Enum.into(attrs, %{email: unique_user_email(), password: @default_password})

    {:ok, user} = Accounts.register_user(attrs)
    {:ok, token} = Accounts.deliver_user_confirmation_instructions(user)
    {:ok, confirmed} = Accounts.confirm_user(token)

    confirmed
  end

  @doc """
  An email address no other fixture in this test run will produce — emails are
  unique per account, and a hard-coded address turns an unrelated second user
  into a duplicate-email crash.
  """
  def unique_user_email, do: "user#{System.unique_integer([:positive])}@bunk.test"

  @doc "The password `confirmed_user_fixture/1` uses unless the caller supplies one."
  def valid_user_password, do: @default_password

  @doc """
  Zet een tweede factor op dit account.

  Het beheerpaneel eist er een (`Plugs.RequireAdminMfa`). Zonder deze regel
  testen de beheerderstests die drempel in plaats van wat ze bedoelen te
  testen -- ze zouden allemaal op dezelfde 403 stranden en niets meer zeggen
  over het paneel erachter.

  Een echte TOTP-inschrijving doorlopen zou hier niets toevoegen: die heeft zijn
  eigen tests, en wat deze fixture moet vastleggen is alleen "dit account heeft
  een tweede factor".
  """
  def with_second_factor(%ControlPlane.Accounts.User{} = user) do
    user
    |> Ecto.Changeset.change(%{
      totp_secret: "ABCDEFGHIJKLMNOP",
      totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> ControlPlane.Repo.update!()
  end
end
