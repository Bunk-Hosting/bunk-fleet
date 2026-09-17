defmodule ControlPlaneWeb.CrossTenantTest do
  @moduledoc """
  De drie `:id`-endpoints die nog geen test hadden waarin gebruiker B bij de
  resource van gebruiker A probeert te komen.

  Het risico dat hier afgedekt wordt is IDOR: elk endpoint dat een id uit het pad
  leest moet het eigenaarschap van die rij controleren en niet alleen of de
  beller ingelogd is. De rest van de klant-API had die dekking al; deze drie niet
  -- `POST /nodes/:id/owner` (alleen de beheerder-variant was gedekt),
  `POST /nodes/:id/region` met een `region_id` (alleen de `region_name`-variant
  was gedekt, en dat is een ander controllerpad naar een andere Fleet-functie)
  en `POST /vpses/:id/start` (alleen met een onbekend id, nooit met een échte
  VPS van iemand anders).

  Elke test eist twee dingen. De statuscode -- 404 en geen 403, want dat een rij
  bestaat is zelf al informatie die een vreemde niet hoort te krijgen -- en dat
  er daarna niets in de database veranderd is. Dat tweede is het punt: een 404
  die onderweg tóch iets heeft gewijzigd is erger dan een 200, omdat niemand hem
  zoekt.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp gebruiker do
    email = "ct-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp ingelogd(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio #{code}"}) |> Repo.insert!()
  end

  defp fleet_node(region, owner \\ nil) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      owner_id: owner && owner.id,
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    })
    |> Repo.insert!()
  end

  defp vps_van(user, region, naam) do
    {:ok, %{vps: vps}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: naam,
        vcpu: 2,
        ram_mb: 4096,
        disk_gb: 50,
        owner_id: user.id,
        owner_email: user.email,
        template_id: 9000
      })

    vps
  end

  # Een VPS zoals hij eruitziet als hij daadwerkelijk op een node draait. Zonder
  # `provider_vm_id` zouden de lifecycle-endpoints al op "nog niet uitgerold"
  # stranden en zou de test niets zeggen over het eigenaarschap.
  defp uitgerold(vps, status) do
    vps
    |> Ecto.Changeset.change(%{
      status: status,
      provider_vm_id: "#{100 + System.unique_integer([:positive])}"
    })
    |> Repo.update!()
  end

  defp commandos(vps_id, kind) do
    Repo.aggregate(from(c in Command, where: c.vps_id == ^vps_id and c.kind == ^kind), :count)
  end

  describe "POST /api/v1/nodes/:id/owner" do
    test "een vreemde kan andermans node niet naar zichzelf schrijven", %{conn: conn} do
      # Het scherpste geval van dit endpoint: lukt dit, dan pakt de aanvaller de
      # hardware van een ander inclusief alle instellingen die eraan hangen
      # (VMID-bereik, gastnaampatroon, aangeboden capaciteit).
      eigenaar = gebruiker()
      vreemde = gebruiker()
      thuis = regio()
      n = fleet_node(thuis, eigenaar)

      assert %{"error" => "not_found"} =
               conn
               |> ingelogd(vreemde)
               |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => vreemde.email})
               |> json_response(404)

      assert Repo.get!(Node, n.id).owner_id == eigenaar.id
    end

    test "een vreemde kan de eigenaar er ook niet afhalen", %{conn: conn} do
      # Een leeg adres betekent "haal de eigenaar eraf". Dat is een andere tak in
      # `parse_owner/1` dan een geldig adres, en die tak loopt langs dezelfde
      # eigenaarscontrole -- maar dat was nergens vastgelegd. Zou hij wegvallen,
      # dan kan een vreemde een node onbeheerd maken en er daarna als enige nog
      # bij (een node zonder eigenaar mag een beheerder toewijzen).
      eigenaar = gebruiker()
      vreemde = gebruiker()
      thuis = regio()
      n = fleet_node(thuis, eigenaar)

      assert conn
             |> ingelogd(vreemde)
             |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => ""})
             |> json_response(404)

      assert Repo.get!(Node, n.id).owner_id == eigenaar.id
    end
  end

  describe "POST /api/v1/nodes/:id/region" do
    test "een vreemde verplaatst andermans node niet op region_id", %{conn: conn} do
      # De `region_name`-variant is gedekt, deze niet -- en het is een aparte
      # clause in de controller die een ándere Fleet-functie aanroept
      # (`move_node_to_region/3` in plaats van `move_node_to_named_region/3`).
      # Twee paden naar dezelfde bevoegdheid betekent dat er twee sloten zijn.
      eigenaar = gebruiker()
      vreemde = gebruiker()
      thuis = regio()
      elders = regio()
      n = fleet_node(thuis, eigenaar)

      assert conn
             |> ingelogd(vreemde)
             |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_id" => elders.id})
             |> json_response(404)

      assert Repo.get!(Node, n.id).region_id == thuis.id
    end

    test "een node zonder eigenaar is ook niet van een willekeurige klant", %{conn: conn} do
      # `mag_overdragen/2` heeft een uitzondering voor een node zonder eigenaar;
      # `move_node_to_region/3` heeft die niet. Als die twee ooit gelijkgetrokken
      # worden, moet dat een bewuste keuze zijn en geen bijvangst.
      vreemde = gebruiker()
      thuis = regio()
      elders = regio()
      n = fleet_node(thuis, nil)

      assert conn
             |> ingelogd(vreemde)
             |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_id" => elders.id})
             |> json_response(404)

      assert Repo.get!(Node, n.id).region_id == thuis.id
    end
  end

  describe "POST /api/v1/vpses/:id/start" do
    setup do
      region = regio()
      _node = fleet_node(region)
      %{region: region}
    end

    test "andermans gestopte VPS start niet en krijgt geen commando", %{
      conn: conn,
      region: region
    } do
      # `stop` is gedekt via de klantreis, `reboot` heeft een eigen test, `start`
      # had er alleen een met een onbekend id -- en een onbekend id bewijst niets
      # over eigenaarschap, alleen dat de query niets vond. Met een echte VPS van
      # een ander erachter test dit wat het moet testen.
      eigenaar = gebruiker()
      vreemde = gebruiker()
      hunne = eigenaar |> vps_van(region, "hunne") |> uitgerold(:stopped)

      assert %{"error" => "not_found"} =
               conn
               |> ingelogd(vreemde)
               |> post(~p"/api/v1/vpses/#{hunne.id}/start")
               |> json_response(404)

      assert Repo.get!(Vps, hunne.id).status == :stopped
      assert commandos(hunne.id, :start) == 0
    end

    test "de eigenaar start hem wel, en dan gaat er wel een commando uit", %{
      conn: conn,
      region: region
    } do
      # De tegenproef. Zonder deze zou een controller die altijd 404 geeft -- een
      # kapotte, maar wel "veilige" controller -- de test hierboven laten slagen.
      eigenaar = gebruiker()
      mijne = eigenaar |> vps_van(region, "mijne") |> uitgerold(:stopped)

      assert conn
             |> ingelogd(eigenaar)
             |> post(~p"/api/v1/vpses/#{mijne.id}/start")
             |> json_response(200)

      assert commandos(mijne.id, :start) == 1
    end
  end

  describe "POST /api/v1/vpses/:id/backups/:backup_id/restore" do
    setup do
      region = regio()
      _node = fleet_node(region)
      %{region: region}
    end

    test "een eigen VPS terugzetten uit andermans back-up raakt die back-up niet", %{
      conn: conn,
      region: region
    } do
      # Dat dit 404 geeft was al vastgelegd. Wat nog niet vastgelegd was: dat de
      # VPS van het slachtoffer er niets van merkt. Zou `restorable/2` ooit van
      # volgorde wisselen en `begin_restoring/2` vóór de eigenaarscontrole
      # draaien, dan zet een vreemde met één verzoek de machine van een ander in
      # :restoring -- en die staat dan stil zonder dat er iemand iets herstelt.
      eigenaar = gebruiker()
      vreemde = gebruiker()

      hunne = eigenaar |> vps_van(region, "hunne") |> uitgerold(:active)
      mijne = vreemde |> vps_van(region, "mijne") |> uitgerold(:active)

      punt =
        %VpsBackup{}
        |> VpsBackup.changeset(%{
          vps_id: hunne.id,
          node_id: hunne.node_id,
          status: :done,
          size_bytes: 1024,
          volid: "local:backup/vzdump-qemu-#{System.unique_integer([:positive])}.vma.zst"
        })
        |> Repo.insert!()

      assert conn
             |> ingelogd(vreemde)
             |> post(~p"/api/v1/vpses/#{mijne.id}/backups/#{punt.id}/restore")
             |> json_response(404)

      # Niets bewogen: niet bij het slachtoffer, niet bij de aanvaller.
      assert Repo.get!(Vps, hunne.id).status == :active
      assert Repo.get!(Vps, mijne.id).status == :active
      assert Repo.get!(VpsBackup, punt.id).status == :done
      assert commandos(hunne.id, :restore_backup) == 0
      assert commandos(mijne.id, :restore_backup) == 0
    end

    test "andermans VPS terugzetten uit zijn eigen back-up geeft ook 404", %{
      conn: conn,
      region: region
    } do
      # De spiegel van het geval hierboven: hier kloppen VPS en back-up bij
      # elkaar, en is het enige dat niet klopt wie het vraagt. `restorable/2`
      # ziet dan geen enkele reden om te weigeren -- de weigering moet dus van
      # `get_vps_for_owner/2` komen.
      eigenaar = gebruiker()
      vreemde = gebruiker()
      hunne = eigenaar |> vps_van(region, "hunne") |> uitgerold(:active)

      punt =
        %VpsBackup{}
        |> VpsBackup.changeset(%{
          vps_id: hunne.id,
          node_id: hunne.node_id,
          status: :done,
          size_bytes: 1024,
          volid: "local:backup/vzdump-qemu-#{System.unique_integer([:positive])}.vma.zst"
        })
        |> Repo.insert!()

      assert conn
             |> ingelogd(vreemde)
             |> post(~p"/api/v1/vpses/#{hunne.id}/backups/#{punt.id}/restore")
             |> json_response(404)

      assert Repo.get!(Vps, hunne.id).status == :active
      assert commandos(hunne.id, :restore_backup) == 0
    end
  end
end
