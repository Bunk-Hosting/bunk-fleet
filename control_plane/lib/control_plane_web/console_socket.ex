defmodule ControlPlaneWeb.ConsoleSocket do
  @moduledoc """
  Raw WebSocket bridge between a browser terminal (xterm.js) and a VPS SSH
  session. Bytes flow both ways: client binary frames are keystrokes forwarded to
  the SSH channel; SSH output is pushed back as binary frames. A text frame
  `{"type":"resize","cols":..,"rows":..}` resizes the PTY. The SSH dial-out is the
  existing `Console.Session` GenServer, started here with this socket as owner.
  """
  @behaviour WebSock
  require Logger
  alias ControlPlane.Console.Session

  # Each live session is a GenServer holding a real SSH connection to a VPS. Cap
  # how many a single user may hold at once so a scripted client can't exhaust
  # control-plane processes/FDs or hammer operator nodes' sshd (authenticated DoS).
  # Sessions register into ControlPlane.Console.Registry under {:user, uid}; the
  # duplicate registry drops dead entries automatically, so this count is live.
  @max_sessions_per_user 5

  @impl true
  def init(state) do
    if session_limit_reached?(state.user_id) do
      Logger.warning(
        "console ws: per-user session limit reached for user #{inspect(state.user_id)}"
      )

      {:stop, :normal, state}
    else
      case Session.start_link(%{
             node_id: state.node_id,
             host: state.host,
             port: state.port,
             user: state.user,
             owner: self(),
             user_id: state.user_id,
             vps_id: state.vps_id
           }) do
        {:ok, pid} ->
          {:ok, Map.put(state, :session, pid)}

        {:error, reason} ->
          Logger.warning("console ws: session start failed: #{inspect(reason)}")
          {:stop, :normal, state}
      end
    end
  end

  defp session_limit_reached?(nil), do: false

  defp session_limit_reached?(user_id) do
    Registry.count_match(ControlPlane.Console.Registry, {:user, user_id}, nil) >=
      @max_sessions_per_user
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, %{session: s} = state) do
    Session.send_input(s, data)
    {:ok, state}
  end

  def handle_in({text, [opcode: :text]}, %{session: s} = state) do
    with {:ok, %{"type" => "resize", "cols" => c, "rows" => r}} <- Jason.decode(text),
         true <- is_integer(c) and is_integer(r) do
      Session.resize(s, c, r)
    end

    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:console_output, data}, state), do: {:push, {:binary, data}, state}
  def handle_info({:console_closed, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
