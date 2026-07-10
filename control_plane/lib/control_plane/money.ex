defmodule ControlPlane.Money do
  @moduledoc """
  Small money helpers, so the euro-`Decimal` → integer-cents conversion lives in
  exactly one place with one rounding rule (`round(0)` = round-half-up to whole
  cents) instead of being copy-pasted across the billing, subscription and
  provisioning code paths.
  """

  @doc """
  Converts a euro amount (`Decimal`) to whole integer cents, rounding to the
  nearest cent.

      iex> ControlPlane.Money.to_cents(Decimal.new("3.99"))
      399
      iex> ControlPlane.Money.to_cents(Decimal.new("14.995"))
      1500
  """
  def to_cents(%Decimal{} = euros) do
    euros |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
  end
end
