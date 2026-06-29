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

  @impl true
  def init(state) do
    case Session.start_link(%{
           host: state.host,
           port: state.port,
           user: state.user,
           owner: self(),
           user_id: state.user_id
         }) do
      {:ok, pid} ->
        {:ok, Map.put(state, :session, pid)}

      {:error, reason} ->
        Logger.warning("console ws: session start failed: #{inspect(reason)}")
        {:stop, :normal, state}
    end
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
