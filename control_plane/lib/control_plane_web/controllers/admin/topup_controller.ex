defmodule ControlPlaneWeb.Admin.TopupController do
  @moduledoc "Admin queue for customer top-up requests; confirming one credits the wallet."
  use ControlPlaneWeb, :controller

  alias ControlPlane.Credits

  def index(conn, _params) do
    json(conn, %{requests: Enum.map(Credits.list_pending_topups(), &request_json/1)})
  end

  def confirm(conn, %{"id" => id}) do
    case Credits.mark_topup_paid(id) do
      {:ok, tr} ->
        json(conn, %{
          id: tr.id,
          reference: tr.reference,
          status: tr.status,
          balance_cents: Credits.balance_cents(tr.user_id)
        })

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "top-up request not found"})

      {:error, :not_pending} ->
        conn |> put_status(:conflict) |> json(%{error: "request is not pending"})
    end
  end

  defp request_json(tr) do
    %{
      id: tr.id,
      email: tr.user && tr.user.email,
      amount_cents: tr.amount_cents,
      reference: tr.reference,
      requested_at: tr.inserted_at
    }
  end
end
