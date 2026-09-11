defmodule ControlPlane.Console.Relay do
  @moduledoc """
  Carries console bytes to a VPS the control plane cannot dial.

  The console SSHes to `vpses.ip_address`. That only works while the control
  plane and the customer network meet at one router, which is true of the first
  node and of nothing else: a node in another building keeps its VPSes on a
  private subnet behind its own NAT, and the control plane has neither a route to
  it nor a public address to be dialled back on.

  So the connection is made the other way round, over the path the agent already
  holds open:

      console  ──▶  Relay ──▶ (queued request)
                              agent polls /v1/commands, sees console_connect
      console  ◀──  Relay ◀── agent dials WSS /v1/console-relay?token=…
                              agent opens TCP to the VPS's SSH port
      bytes flow: ssh ⇄ loopback pair ⇄ Relay ⇄ WebSocket ⇄ agent ⇄ VPS

  Every console goes this way, including on nodes the control plane *could*
  reach. One path is testable; two paths diverge and the rarely-used one is the
  one that breaks.

  ## Why a loopback socket pair

  `:ssh.connect/3` takes an already-connected socket, but there is no way to hand
  it an arbitrary byte stream. So the relay connects a TCP socket to a listener of
  its own on `127.0.0.1`: one end goes to `:ssh`, the other is pumped against the
  agent's WebSocket. A nonce is exchanged across the pair before use, so a local
  process that raced us to the listener is detected rather than spoken to.
  """
  use GenServer
  require Logger

  alias ControlPlane.Console.Tickets

  @registry ControlPlane.Console.Relay.Registry
  @nonce_bytes 16
  # How long the agent has to dial back before the console gives up. The agent
  # polls every couple of seconds; anything beyond this is a node that is not
  # coming.
  @attach_timeout_ms 15_000

  # --- requests waiting to be polled ----------------------------------------

  @doc """
  Opens a relay for `vps` on `node`, returning `{:ok, socket, pid}`.

  `socket` is a connected TCP socket to give to `:ssh.connect/3`; its peer is this
  relay. The caller is linked to the relay, so a browser that goes away tears the
  whole chain down.
  """
  def open(node_id, vps_id, host, port \\ 22) do
    token = Tickets.random_token()

    with {:ok, pid} <- start_relay(token, node_id, vps_id, host, port),
         {:ok, socket} <- GenServer.call(pid, :take_socket, @attach_timeout_ms + 1_000) do
      {:ok, socket, pid}
    end
  end

  @doc """
  The console requests queued for `node_id`, as agent-facing command maps.

  Drains the queue: a request is handed out once. The agent that fails to dial
  back leaves the console to time out rather than being retried, because by then
  the person has already clicked again.
  """
  def take_for_node(node_id) do
    @registry
    |> Registry.select([
      {{:"$1", :"$2", :"$3"}, [{:==, {:map_get, :node_id, :"$3"}, node_id}], [:"$3"]}
    ])
    |> Enum.flat_map(fn %{pid: pid} ->
      try do
        case GenServer.call(pid, :take_request, 1_000) do
          {:ok, request} -> [request]
          :already_taken -> []
        end
      catch
        # A relay that died between the lookup and the call is simply not
        # offering work; it must not take the whole poll down with it.
        :exit, _ -> []
      end
    end)
  end

  @doc """
  Attaches an agent's WebSocket to the relay holding `token`.

  `node_id` is the node the agent authenticated as. A relay belongs to exactly one
  node, so a token that leaked to a *different* operator's agent buys nothing —
  which matters in a fleet where the nodes are not all ours.

  Returns `{:ok, pid}`, or `:error` when the token is unknown, expired, already
  attached, or belongs to another node. All of those are one answer to the caller:
  do not talk to it.
  """
  def attach(token, node_id, ws_pid) when is_binary(token) and is_pid(ws_pid) do
    case Registry.lookup(@registry, token) do
      [{pid, %{node_id: ^node_id}}] -> GenServer.call(pid, {:attach, ws_pid}, 5_000)
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  @doc "Bytes arriving from the agent, headed for the SSH client."
  def from_agent(pid, data) when is_binary(data), do: GenServer.cast(pid, {:from_agent, data})

  @doc "The agent's side went away; close the console with it."
  def agent_closed(pid), do: GenServer.cast(pid, :agent_closed)

  # --- server ---------------------------------------------------------------

  defp start_relay(token, node_id, vps_id, host, port) do
    DynamicSupervisor.start_child(
      ControlPlane.Console.RelaySupervisor,
      {__MODULE__,
       %{
         token: token,
         node_id: node_id,
         vps_id: vps_id,
         host: host,
         port: port,
         owner: self()
       }}
    )
  end

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(%{token: token, node_id: node_id, vps_id: vps_id, host: host, port: port, owner: owner}) do
    Process.flag(:trap_exit, true)
    Process.link(owner)

    {:ok, _} = Registry.register(@registry, token, %{pid: self(), node_id: node_id})

    {:ok,
     %{
       token: token,
       node_id: node_id,
       vps_id: vps_id,
       host: host,
       port: port,
       request_taken: false,
       ws: nil,
       sock: nil,
       listener: nil
     }, {:continue, :arm}}
  end

  @impl true
  def handle_continue(:arm, state) do
    # The console is waiting on take_socket; if the agent never dials back, stop
    # rather than leaving a process and a listener behind.
    Process.send_after(self(), :attach_timeout, @attach_timeout_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:take_socket, {caller, _tag}, state) do
    case loopback_pair() do
      {:ok, ssh_side, relay_side, listener} ->
        # :ssh reads from the socket itself, so the caller has to own it — a
        # socket still owned by this process would deliver its data here instead.
        :ok = :gen_tcp.controlling_process(ssh_side, caller)
        :ok = :inet.setopts(relay_side, active: true)
        {:reply, {:ok, ssh_side}, %{state | sock: relay_side, listener: listener}}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:take_request, _from, %{request_taken: true} = state) do
    {:reply, :already_taken, state}
  end

  def handle_call(:take_request, _from, state) do
    request = %{
      "id" => state.token,
      "kind" => "console_connect",
      "payload" => %{
        "token" => state.token,
        "vps_id" => state.vps_id,
        "host" => state.host,
        "port" => state.port
      }
    }

    {:reply, {:ok, request}, %{state | request_taken: true}}
  end

  def handle_call({:attach, ws_pid}, _from, %{ws: nil} = state) do
    Process.monitor(ws_pid)
    # SSH may already have written its version banner while we were waiting.
    for data <- Enum.reverse(Map.get(state, :pending_out, [])),
        do: send(ws_pid, {:relay_out, data})

    {:reply, {:ok, self()}, %{state | ws: ws_pid} |> Map.put(:pending_out, [])}
  end

  # Already attached: a second socket for the same token is a replay, not a retry.
  def handle_call({:attach, _ws_pid}, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_cast({:from_agent, data}, %{sock: sock} = state) when not is_nil(sock) do
    case :gen_tcp.send(sock, data) do
      :ok -> {:noreply, state}
      {:error, _closed} -> {:stop, :normal, state}
    end
  end

  def handle_cast({:from_agent, _data}, state), do: {:noreply, state}

  def handle_cast(:agent_closed, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:tcp, _sock, data}, %{ws: ws} = state) when is_pid(ws) do
    send(ws, {:relay_out, data})
    {:noreply, state}
  end

  # SSH started talking before the agent attached. Dropping the bytes would
  # corrupt the handshake, so hold them until the WebSocket arrives.
  def handle_info({:tcp, _sock, data}, state) do
    {:noreply, Map.update(state, :pending_out, [data], &[data | &1])}
  end

  def handle_info({:tcp_closed, _sock}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _sock, _reason}, state), do: {:stop, :normal, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:stop, :normal, state}

  def handle_info(:attach_timeout, %{ws: nil} = state) do
    Logger.info("console relay: node #{state.node_id} did not dial back in time")
    {:stop, :normal, state}
  end

  def handle_info(:attach_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.sock, do: :gen_tcp.close(state.sock)
    if state.listener, do: :gen_tcp.close(state.listener)
    :ok
  end

  # --- loopback pair --------------------------------------------------------

  # Two ends of one TCP connection over the loopback interface: the returned
  # `ssh_side` is what :ssh.connect/3 is given, `relay_side` is what this process
  # pumps. The nonce proves the accepted socket is the one we just dialled and not
  # a local process that raced us onto the listener.
  defp loopback_pair do
    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             ip: {127, 0, 0, 1},
             active: false,
             packet: :raw,
             backlog: 1
           ]),
         {:ok, port} <- :inet.port(listener),
         {:ok, ssh_side} <-
           :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000),
         {:ok, relay_side} <- :gen_tcp.accept(listener, 5_000),
         nonce = :crypto.strong_rand_bytes(@nonce_bytes),
         :ok <- :gen_tcp.send(ssh_side, nonce),
         {:ok, ^nonce} <- :gen_tcp.recv(relay_side, @nonce_bytes, 5_000) do
      {:ok, ssh_side, relay_side, listener}
    else
      other ->
        Logger.error("console relay: could not build loopback pair: #{inspect(other)}")
        {:error, :relay_unavailable}
    end
  end
end
