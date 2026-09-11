defmodule ControlPlane.Console.RelayTest do
  # async: false — relays register in a named registry the whole node shares, and
  # take_for_node/1 selects across it, so a concurrent test's relay would show up
  # in this one's poll.
  use ExUnit.Case, async: false

  alias ControlPlane.Console.Relay

  @node_a "node-a"
  @node_b "node-b"
  @vps "vps-1"
  @host "10.10.4.20"

  # No cleanup: the relay links whoever opened it, so it dies with the test that
  # opened it. That is the same mechanism that closes a console when the browser
  # goes away, and the last test in this file is what proves it.
  defp open(node_id \\ @node_a) do
    {:ok, local_port, relay} = Relay.open(node_id, @vps, @host, 22)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, local_port, [:binary, active: false], 1_000)
    {socket, relay}
  end

  defp token_of(node_id) do
    [request] = Relay.take_for_node(node_id)
    request["payload"]["token"]
  end

  describe "the request handed to the agent" do
    test "names the VPS, the address to dial, and a token" do
      {_socket, _relay} = open()

      assert [request] = Relay.take_for_node(@node_a)
      assert request["kind"] == "console_connect"
      assert request["payload"]["vps_id"] == @vps
      assert request["payload"]["host"] == @host
      assert request["payload"]["port"] == 22
      assert byte_size(request["payload"]["token"]) >= 32
    end

    test "is handed out once, not on every poll" do
      {_socket, _relay} = open()

      assert [_request] = Relay.take_for_node(@node_a)
      assert [] = Relay.take_for_node(@node_a)
    end

    test "goes only to the node the VPS is on" do
      {_socket, _relay} = open(@node_a)

      assert [] = Relay.take_for_node(@node_b)
      assert [_request] = Relay.take_for_node(@node_a)
    end
  end

  describe "attaching an agent" do
    test "the agent that dials back with the token is joined to the relay" do
      {_socket, relay} = open()
      token = token_of(@node_a)

      assert {:ok, ^relay} = Relay.attach(token, @node_a, self())
    end

    test "a token from another node's agent is refused" do
      {_socket, _relay} = open(@node_a)
      token = token_of(@node_a)

      # The nodes are not all ours. A relay token that leaked to a different
      # operator's agent must not open a console on someone else's machine.
      assert :error = Relay.attach(token, @node_b, self())
    end

    test "a second attach for the same token is a replay, not a retry" do
      {_socket, _relay} = open()
      token = token_of(@node_a)

      assert {:ok, _pid} = Relay.attach(token, @node_a, self())
      assert :error = Relay.attach(token, @node_a, self())
    end

    test "an unknown token attaches to nothing" do
      assert :error = Relay.attach("not-a-real-token", @node_a, self())
    end
  end

  describe "carrying bytes" do
    test "what SSH writes reaches the agent" do
      {socket, _relay} = open()
      token = token_of(@node_a)
      {:ok, _pid} = Relay.attach(token, @node_a, self())

      :ok = :gen_tcp.send(socket, "SSH-2.0-bunk\r\n")

      assert_receive {:relay_out, "SSH-2.0-bunk\r\n"}, 1_000
    end

    test "bytes written before the agent attaches are held, not dropped" do
      # SSH sends its version banner the moment the socket is up, which is before
      # the agent has had a chance to poll. Losing it corrupts the handshake.
      {socket, _relay} = open()
      :ok = :gen_tcp.send(socket, "SSH-2.0-early\r\n")
      Process.sleep(50)

      token = token_of(@node_a)
      {:ok, _pid} = Relay.attach(token, @node_a, self())

      assert_receive {:relay_out, "SSH-2.0-early\r\n"}, 1_000
    end

    test "what the agent sends reaches SSH" do
      {socket, relay} = open()
      token = token_of(@node_a)
      {:ok, _pid} = Relay.attach(token, @node_a, self())

      Relay.from_agent(relay, "SSH-2.0-openssh\r\n")

      assert {:ok, "SSH-2.0-openssh\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
    end
  end

  describe "teardown" do
    test "the agent going away closes the SSH side" do
      {socket, relay} = open()
      token = token_of(@node_a)
      {:ok, _pid} = Relay.attach(token, @node_a, self())

      Relay.agent_closed(relay)

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    test "the console going away stops the relay" do
      # The relay links its owner, so a browser that disappears must not leave a
      # process and a listening socket behind.
      parent = self()

      owner =
        spawn(fn ->
          {:ok, _local_port, relay} = Relay.open(@node_a, @vps, @host, 22)
          send(parent, {:relay, relay})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:relay, relay}, 1_000
      ref = Process.monitor(relay)

      send(owner, :stop)

      assert_receive {:DOWN, ^ref, :process, ^relay, _reason}, 1_000
    end
  end
end
