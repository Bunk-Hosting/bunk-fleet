defmodule ControlPlane.Console.HostKeys do
  @moduledoc """
  Trust-on-first-use (TOFU) pinning of VPS SSH host keys for the browser console.

  The first console connection to a VPS records its host-key fingerprint; every
  later connection must present the same fingerprint or it is rejected. This is
  what stops the hosting operator — who controls the hypervisor and the overlay
  network — from transparently MITMing a customer's console session (O-33).

  TOFU's one inherent gap is the very first connection: if the operator already
  sits in the path then, the attacker's key gets pinned. That is acceptable here
  (the same trust assumption as SSH itself) and is the price of not shipping
  out-of-band host keys; a future hardening is to capture the key at provision.
  """
  import Ecto.Query
  require Logger

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.Vps

  @doc """
  Verifies a presented host-key `fingerprint` (a `"SHA256:..."` string) against the
  VPS's pin, pinning it on first sight. Returns `true` to accept the SSH
  connection, `false` to reject it.

  A `nil` `vps_id` (no pin context threaded through, e.g. a legacy caller) accepts
  without pinning so the console keeps working — pinning is best-effort hardening,
  not an availability dependency.
  """
  def verify(nil, _fingerprint), do: true

  def verify(vps_id, fingerprint) when is_binary(fingerprint) do
    case Repo.one(from v in Vps, where: v.id == ^vps_id, select: v.ssh_host_key) do
      # First connect (no pin yet, or the row is gone): pin it. The is_nil guard
      # makes concurrent first-connects converge — same host means same
      # fingerprint, so first writer wins and the rest are harmless no-ops.
      nil ->
        {n, _} =
          Repo.update_all(
            from(v in Vps, where: v.id == ^vps_id and is_nil(v.ssh_host_key)),
            set: [ssh_host_key: fingerprint]
          )

        if n > 0, do: Logger.info("console: pinned ssh host key #{fingerprint} for vps #{vps_id}")
        true

      ^fingerprint ->
        true

      _other ->
        Logger.error(
          "console: ssh host key MISMATCH for vps #{vps_id} (got #{fingerprint}) — " <>
            "rejecting connection (possible operator MITM)"
        )

        false
    end
  end

  def verify(_vps_id, _fingerprint), do: false
end
