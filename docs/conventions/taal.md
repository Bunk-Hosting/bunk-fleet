# Taal in deze repo

`CODE_GUIDELINES.md` verwees naar deze map zonder dat hij bestond, en de
codekwaliteit-review merkte terecht op dat Nederlands en Engels door elkaar
lopen binnen dezelfde module. Dat is geen conventie maar drift. Hieronder staat
wat de code inmiddels feitelijk doet, zodat de volgende die hier iets aanraakt
niet opnieuw hoeft te raden.

## De regel

**Nieuw werk is Nederlands.** Commentaar, moduledocs, commitberichten,
foutmeldingen die een mens leest, en de namen van functies die over het domein
gaan.

**Bestaand Engels blijft staan** tot de code waar het bij hoort toch al wordt
herschreven. Een bestand vertalen "omdat het nu eenmaal moet" levert een diff op
waarin niemand de echte wijziging meer ziet, en dat is een slechtere ruil dan
twee talen naast elkaar.

## Wat Engels blijft, ook in nieuw werk

- **Namen uit het raamwerk of het protocol.** `changeset`, `plug`, `socket`,
  `handle_info`, `GenServer`, HTTP-koppen, JSON-sleutels die over de lijn gaan,
  kolomnamen die al bestaan.
- **Vaktermen zonder bruikbare vertaling.** `heartbeat`, `rate limit`,
  `idempotent`, `hash`, `token`. Een gedwongen vertaling maakt het onvindbaar:
  wie `hartslag` zoekt vindt niets.
- **Alles wat een externe partij leest.** Publieke API-velden, de
  `docs/protocol.md`, en `docs/runbooks/add-a-node.md`, dat geschreven is voor
  operators die niet per se Nederlands lezen.

## Waarom Nederlands en niet Engels

Twee redenen, en de eerste is de belangrijkste.

Commentaar bestaat om uit te leggen *waarom* iets zo staat — niet wat er staat,
dat leest de lezer zelf. Die uitleg is precies het stuk waar nuance in zit, en
nuance schrijf je het scherpst in je eigen taal. De uitleg bij
`begrens_met_id/2` of bij de keuze om de controle op gelekte wachtwoorden open
te laten vallen, zou in het Engels een graad vager zijn geworden.

En Bunk is een Nederlandse dienst met Nederlandse klanten, Nederlandse
voorwaarden en Nederlandse wetgeving in de runbooks. Een foutmelding die een
klant ziet is Nederlands; dan is het raar als de code die hem produceert in een
andere taal over hem praat.

## Voorbeelden uit de code zelf

| | |
|---|---|
| `normaliseerHost` (Go) | domeinbegrip, Nederlands |
| `magBridgeGebruiken` (Go) | idem |
| `Privacy.Export.verzamel/1` | idem |
| `plaatsnaam?/1` | idem |
| `heartbeat_changeset/2` | raamwerk + protocol, Engels |
| `Fleet.Command.kind` | gaat over de lijn, Engels |

## Wat dit niet is

Geen reden om een bestaande module half te vertalen, en geen reden om een
commit af te keuren omdat er een Engelse zin in staat. De gate controleert dit
niet en dat blijft zo: dit is een afspraak tussen mensen, geen regel die een
machine kan handhaven zonder meer kwaad dan goed te doen.
