defmodule ControlPlane.Privacy.Export do
  @moduledoc """
  Alles wat Bunk over één persoon weet, als één JSON-document.

  De AVG geeft iedereen recht op inzage (art. 15) en op overdraagbaarheid
  (art. 20), en dat tweede vraagt om "een gestructureerde, gangbare en
  machineleesbare vorm". Zonder dit was het antwoord op zo'n verzoek een middag
  handmatig queries schrijven, en dat is precies het soort antwoord dat te laat
  komt of onvolledig is.

  ## Wat er NIET in staat

  Geen wachtwoordhash, geen TOTP-geheim, geen publieke sleutel van een passkey en
  geen sessietokens. Dat zijn geen gegevens *over* de persoon maar sleutels *van*
  de persoon: ze zeggen hem niets nieuws en een export is een bestand dat per
  definitie gaat rondzwerven -- per mail, in een downloadmap, in een back-up van
  zijn laptop. Van een passkey staat er dus wel dát hij bestaat, met label en
  laatste gebruik, want dat is inzage; de sleutel zelf niet.

  Van sessies geldt hetzelfde met een extra reden: een geldig sessietoken in een
  exportbestand is een overgenomen account.

  ## Verbruik wordt samengevat

  `usage_records` groeit met een rij per VPS per dertig seconden. Een jaar met
  één VPS is al ruim een miljoen rijen, en die uitdraaien geeft iemand geen
  inzage maar een bestand dat hij niet kan openen. Daarom per VPS per maand:
  hoeveel uur, en waarvoor. Wie de losse regels wil -- en dat recht bestaat --
  krijgt ze op verzoek; dat is dan een bewuste handeling en geen bijvangst.
  """
  import Ecto.Query

  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Accounts.User
  alias ControlPlane.Console.Sessielog
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  @doc """
  Verzamelt alles over `email`.

  Geeft `{:ok, map}` of `{:error, :not_found}`. De map is met `Jason.encode/1`
  te serialiseren.
  """
  @spec verzamel(String.t()) :: {:ok, map()} | {:error, :not_found}
  def verzamel(email) when is_binary(email) do
    genormaliseerd = email |> String.trim() |> String.downcase()

    case Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^genormaliseerd) do
      nil ->
        {:error, :not_found}

      %User{} = user ->
        {:ok,
         %{
           export: %{
             opgesteld_op: DateTime.utc_now() |> DateTime.to_iso8601(),
             toelichting:
               "Alles wat Bunk Hosting over deze persoon vastlegt. Sleutels " <>
                 "(wachtwoord, tweede factor, passkeys, sessies) staan hier bewust niet in; " <>
                 "zie de module-documentatie van ControlPlane.Privacy.Export."
           },
           account: account(user),
           vpsen: vpsen(user),
           abonnementen: abonnementen(user),
           tegoed: tegoed(user),
           opwaarderingen: opwaarderingen(user),
           passkeys: passkeys(user),
           nodes: nodes(user),
           terminalsessies: terminalsessies(user),
           verbruik_per_maand: verbruik(user)
         }}
    end
  end

  defp account(%User{} = u) do
    %{
      id: u.id,
      email: u.email,
      naam: u.name,
      rol: u.role,
      bevestigd_op: iso(u.confirmed_at),
      geanonimiseerd_op: iso(u.anonymised_at),
      tweede_factor_actief: not is_nil(u.totp_confirmed_at),
      aangemaakt_op: iso(u.inserted_at)
    }
  end

  defp vpsen(%User{id: id}) do
    Repo.all(from v in Vps, where: v.owner_id == ^id, order_by: v.inserted_at)
    |> Enum.map(fn v ->
      %{
        id: v.id,
        naam: v.name,
        status: v.status,
        vcpu: v.vcpu,
        ram_mb: v.ram_mb,
        schijf_gb: v.disk_gb,
        ip_adres: v.ip_address,
        aangemaakt_op: iso(v.inserted_at),
        # Het moment waarop deze klant afstand deed van zijn herroepingsrecht.
        # Hoort in een inzageverzoek: het is een rechtshandeling van hemzelf.
        directe_levering_akkoord_op: iso(v.withdrawal_waiver_at)
      }
    end)
  end

  defp abonnementen(%User{id: id}) do
    Repo.all(from s in Subscription, where: s.owner_id == ^id, order_by: s.inserted_at)
    |> Enum.map(fn s ->
      %{
        id: s.id,
        vps_id: s.vps_id,
        prijs_per_maand: s.price_monthly && Decimal.to_string(s.price_monthly),
        status: s.status,
        gestart_op: iso(s.started_at),
        volgende_facturatiedatum: s.next_billing_date && Date.to_iso8601(s.next_billing_date),
        opgezegd_op: iso(s.cancelled_at)
      }
    end)
  end

  defp tegoed(%User{id: id}) do
    regels =
      Repo.all(from e in LedgerEntry, where: e.user_id == ^id, order_by: e.inserted_at)
      |> Enum.map(fn e ->
        %{
          datum: iso(e.inserted_at),
          bedrag_centen: e.amount_cents,
          soort: e.kind,
          omschrijving: e.description,
          vps_id: e.vps_id
        }
      end)

    %{saldo_centen: Enum.reduce(regels, 0, &(&1.bedrag_centen + &2)), regels: regels}
  end

  defp opwaarderingen(%User{id: id}) do
    Repo.all(from t in TopupRequest, where: t.user_id == ^id, order_by: t.inserted_at)
    |> Enum.map(fn t ->
      %{
        referentie: t.reference,
        bedrag_centen: t.amount_cents,
        status: t.status,
        betaald_op: iso(t.paid_at),
        bevestigd_door: t.paid_via,
        betaling_id_bij_provider: t.mollie_payment_id
      }
    end)
  end

  defp passkeys(%User{id: id}) do
    Repo.all(from p in Passkey, where: p.user_id == ^id, order_by: p.inserted_at)
    |> Enum.map(fn p ->
      %{
        label: p.label,
        aangemaakt_op: iso(p.inserted_at),
        laatst_gebruikt_op: iso(p.last_used_at)
      }
    end)
  end

  # Een node is van een persoon, en dat feit is een persoonsgegeven over hem --
  # ook al gaat de rij verder over hardware.
  defp nodes(%User{id: id}) do
    Repo.all(from n in Node, where: n.owner_id == ^id, order_by: n.inserted_at)
    |> Enum.map(fn n ->
      %{
        naam: n.name,
        status: n.status,
        hypervisor: n.hypervisor,
        aangemeld_op: iso(n.inserted_at)
      }
    end)
  end

  # Wie er op de terminal van zijn machines heeft gezeten -- inclusief wij.
  #
  # Dit hoort in een inzageverzoek en niet alleen in onze eigen administratie.
  # Bunk heeft root op elke VPS (de consolesleutel staat in de authorized_keys)
  # en dat is niet weg te nemen zonder de webterminal weg te nemen. Wat wel kan
  # is het narekenbaar maken: een klant hoort te kunnen zien dát er niemand is
  # geweest in plaats van het te moeten geloven.
  defp terminalsessies(%User{id: id}) do
    Repo.all(from v in Vps, where: v.owner_id == ^id, select: v.id)
    |> Sessielog.voor_vpsen()
    |> Enum.map(fn r ->
      %{
        vps_id: r.vps_id,
        begonnen_op: iso(r.started_at),
        geeindigd_op: iso(r.ended_at),
        door_bunk: r.door_beheerder
      }
    end)
  end

  defp verbruik(%User{email: email}) do
    Repo.all(
      from u in "usage_records",
        where: u.owner_email == ^email,
        group_by: [u.vps_id, fragment("date_trunc('month', ?)", u.metered_at)],
        order_by: [fragment("date_trunc('month', ?)", u.metered_at)],
        select: %{
          vps_id: type(u.vps_id, :binary_id),
          maand: fragment("to_char(date_trunc('month', ?), 'YYYY-MM')", u.metered_at),
          seconden: coalesce(sum(u.seconds), 0)
        }
    )
    |> Enum.map(fn r ->
      %{
        vps_id: r.vps_id,
        maand: r.maand,
        uren: Float.round(r.seconden / 3600, 2)
      }
    end)
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
