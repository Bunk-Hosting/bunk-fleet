defmodule ControlPlane.Repo.Migrations.VpsWithdrawalWaiver do
  use Ecto.Migration

  # Wanneer de besteller bevestigde dat de VPS meteen mag worden aangemaakt.
  #
  # Een consument heeft veertien dagen bedenktijd. Die vervalt alleen als hij
  # uitdrukkelijk om onmiddellijke levering vraagt én erkent daarmee zijn
  # herroepingsrecht te verliezen (art. 6:230p sub f BW). De bewijslast dat die
  # bevestiging er was ligt bij ons, dus is het een kolom en geen aanname.
  #
  # Nullable, want elke VPS die voor deze migratie is aangemaakt heeft de vraag
  # nooit gekregen. NULL betekent hier "niet gevraagd", niet "geweigerd" — het
  # verschil is belangrijk genoeg om het hier op te schrijven, want een lege
  # kolom die met terugwerkende kracht iets lijkt te betekenen heeft in deze
  # codebase al eerder een boeking scheefgetrokken.
  def change do
    alter table(:vpses) do
      add :withdrawal_waiver_at, :utc_datetime
    end
  end
end
