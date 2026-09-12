defmodule ControlPlane.Time do
  @moduledoc """
  The one place that says what "now" means here.

  Every `utc_datetime` column in this schema stores whole seconds, and Ecto
  refuses a `DateTime` carrying microseconds rather than rounding it — so
  truncating is not a style choice, it is what makes a write succeed. That rule
  was being re-derived at nineteen call sites; one of them forgetting is an
  exception in production, on a path that probably only runs when something else
  has already gone wrong.
  """

  @doc "The current UTC time, truncated to the second the database stores."
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  `now/0` shifted by `seconds`. Negative shifts back, which is how every "older
  than" cutoff in the sweeps is expressed.
  """
  @spec shift(integer()) :: DateTime.t()
  def shift(seconds), do: DateTime.add(now(), seconds, :second)
end
