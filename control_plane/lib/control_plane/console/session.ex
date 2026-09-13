defmodule ControlPlane.Console.Session do
  @moduledoc """
  Bridges a browser terminal to a VPS over SSH. The console WebSocket (ConsoleSocket) starts one (linked),
  it dials the VPS with the platform console key, allocates a PTY + shell, forwards
  channel output to the owning LiveView as `{:console_output, binary}`, and accepts
  `send_input/2` / `resize/3`. The connect runs in `handle_continue` so the caller
  (mount) never blocks. The process traps exits, so closing the tab (a linked
  LiveView exit) deterministically tears the SSH connection down.
  """
  use GenServer
  require Logger

  alias ControlPlane.Console.Relay

  @max_input 65_536
  @max_dim 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def send_input(pid, data), do: GenServer.cast(pid, {:input, data})
  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})

  @impl true
  def init(%{host: host, port: port, user: user, owner: owner} = opts) do
    Process.flag(:trap_exit, true)

    if uid = opts[:user_id] do
      Registry.register(ControlPlane.Console.Registry, {:user, uid}, nil)
    end

    state = %{
      conn: nil,
      chan: nil,
      owner: owner,
      node_id: opts[:node_id],
      host: host,
      port: port,
      user: user,
      vps_id: opts[:vps_id]
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, st) do
    _ = start_ssh()
    key = (Application.get_env(:control_plane, :console) || [])[:ssh_private_key]

    if is_nil(key) do
      notify_closed(st.owner, :no_console_key)
      {:stop, :normal, st}
    else
      opts = [
        user: String.to_charlist(st.user),
        # TOFU host-key pinning is enforced in KeyCb.is_host_key/5 (it pins on first
        # sight and returns false on a mismatch). When it returns false OTP would
        # otherwise PROMPT on stdin for [y/n] — which hangs a headless daemon — so
        # this fun is the non-interactive fallback: refuse the unknown/changed key
        # outright (fail closed) instead of prompting.
        silently_accept_hosts: fn _peer, _fingerprint -> false end,
        key_cb: {ControlPlane.Console.KeyCb, [pem: key, vps_id: st.vps_id]},
        auth_methods: ~c"publickey",
        connect_timeout: 10_000
      ]

      with {:ok, conn} <- connect(st, opts),
           {:ok, chan} <- open_shell_or_close(conn) do
        {:noreply, %{st | conn: conn, chan: chan}}
      else
        {:error, reason} ->
          notify_closed(st.owner, reason)
          {:stop, :normal, st}
      end
    end
  end

  # A connection whose shell won't open is a connection nobody will ever close,
  # so close it here rather than leaking it into the caller's error path.
  defp open_shell_or_close(conn) do
    case open_shell(conn) do
      {:ok, chan} ->
        {:ok, chan}

      {:error, reason} ->
        :ssh.close(conn)
        {:error, reason}
    end
  end

  # Always through the node's own agent, never straight at the VPS. The control
  # plane can only dial a VPS while it happens to share a router with it, which is
  # true of the first node and of no node in another building; routing every
  # console the same way means the path a remote operator uses is the path that
  # gets exercised every day.
  defp connect(st, opts) do
    case Relay.open(st.node_id, st.vps_id, st.host, st.port) do
      # The relay listens on loopback and forwards to the VPS through its node's
      # agent, so "127.0.0.1" here is the VPS. Host-key pinning is unaffected:
      # KeyCb pins per VPS id, never per address, which is exactly why it takes
      # one.
      {:ok, local_port, _relay} -> :ssh.connect(~c"127.0.0.1", local_port, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_ssh do
    case :ssh.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  end

  defp open_shell(conn) do
    with {:ok, chan} <- :ssh_connection.session_channel(conn, 10_000),
         :success <-
           :ssh_connection.ptty_alloc(conn, chan, [
             {:term, ~c"xterm-256color"},
             {:width, 80},
             {:height, 24}
           ]),
         :ok <- :ssh_connection.shell(conn, chan) do
      {:ok, chan}
    else
      other -> {:error, other}
    end
  end

  # Logged as well as sent on: the customer gets a sentence, and whoever is asked
  # "why could they not reach their machine" gets the term OTP actually produced.
  defp notify_closed(owner, reason) do
    Logger.info("console session ended: #{inspect(reason)}")
    send(owner, {:console_closed, reason})
  end

  @impl true
  def handle_cast({:input, data}, %{conn: conn, chan: chan} = st)
      when not is_nil(conn) and is_binary(data) and byte_size(data) <= @max_input do
    :ssh_connection.send(conn, chan, data)
    {:noreply, st}
  end

  def handle_cast({:resize, cols, rows}, %{conn: conn, chan: chan} = st)
      when not is_nil(conn) and is_integer(cols) and is_integer(rows) and
             cols > 0 and rows > 0 and cols <= @max_dim and rows <= @max_dim do
    :ssh_connection.window_change(conn, chan, cols, rows)
    {:noreply, st}
  end

  def handle_cast(_msg, st), do: {:noreply, st}

  @impl true
  def handle_info({:ssh_cm, conn, {:data, chan, _type, data}}, st) do
    send(st.owner, {:console_output, data})
    :ssh_connection.adjust_window(conn, chan, byte_size(data))
    {:noreply, st}
  end

  def handle_info({:ssh_cm, _conn, {:closed, _chan}}, st) do
    notify_closed(st.owner, :remote_closed)
    {:stop, :normal, st}
  end

  def handle_info({:ssh_cm, _conn, _msg}, st), do: {:noreply, st}
  def handle_info({:EXIT, _from, _reason}, st), do: {:stop, :normal, st}
  def handle_info(_other, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    if is_map(st) and st[:conn], do: :ssh.close(st.conn)
    :ok
  end
end
