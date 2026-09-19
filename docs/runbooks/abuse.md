# Runbook — misbruikmeldingen

**Waarvoor dit bestaat.** Er staat een abuse-adres op de site en Bunk is live.
De eerste melding die blijft liggen is niet alleen slordig: de vrijstelling van
aansprakelijkheid voor wat klanten hosten (art. 6:196c BW, DSA art. 6) hangt
eraan dat je **prompt** handelt zodra je weet. Zonder een spoor van wat je
wanneer hebt gedaan, is "prompt" in een procedure niet hard te maken.

Het tweede doel is jezelf beschermen. De vraag "hoe ver mag ik in de VPS van een
klant kijken" moet beantwoord zijn vóórdat er een melding ligt die je nieuwsgierig
maakt.

---

## 1. Wat een melding moet bevatten

De DSA (art. 16 lid 2) vraagt vier dingen. Krijg je ze niet, vraag er dan naar —
een melding die niet zegt waaróm iets illegaal is, is geen melding waarop je
hoeft te handelen, en je mag hem niet gebruiken als grond om iemand af te
sluiten.

1. Een onderbouwing waarom de inhoud onrechtmatig is.
2. Het exacte IP-adres, domein of pad.
3. Naam en e-mailadres van de melder (mag ontbreken bij CSAM of
   terrorisme-gerelateerde meldingen).
4. Een verklaring dat de melding te goeder trouw en naar waarheid is.

## 2. Wat er binnen een dag moet gebeuren

1. **Ontvangstbevestiging** met een zaaknummer (sjabloon A). Dit is een
   verplichting, geen beleefdheid.
2. **Registreer** de melding (§5).
3. **Beoordeel** volgens de trap in §3. Kom je er zonder in de VPS te kijken —
   en dat kan vaker dan je denkt — dan blijf je daar.

Streeftermijn: **binnen 24 uur bevestigen, binnen 72 uur een besluit**, sneller
bij iets wat actief schade aanricht (spam, scan, DDoS: direct).

## 3. Hoe ver je mag kijken

Vier tredes, van licht naar zwaar. Je gaat pas een trede hoger als de vorige het
antwoord niet geeft, en elke trede vanaf 2 komt in het register met datum en
reden.

**Trede 1 — metadata buiten de VPS.** Netflow, verkeersvolume, doel-IP's,
poortgebruik. Geen inhoud. Dit mag zonder aanleiding en is genoeg voor het
overgrote deel van de meldingen: spam, portscans, deelname aan een DDoS.

**Trede 2 — procesniveau in de VPS.** Draaiende processen, luisterende poorten,
cron. Alleen na een concrete melding. Logregel verplicht.

**Trede 3 — bestandsinhoud.** Alleen bij een concrete, onderbouwde melding die
zonder inhoud niet te beoordelen is (auteursrecht, een phishingpagina). Alleen
het genoemde pad, nooit de rest van de schijf. Altijd gelogd. De klant wordt
achteraf geïnformeerd dat je gekeken hebt en waarnaar.

**Trede 4 — bevriezen zonder kijken.** Bij CSAM of een dreiging voor leven of
veiligheid: machine stoppen, **niet wissen**, niet zelf rondkijken. Dat laatste
is geen kiesheid maar zelfbescherming — bezit van dat materiaal is strafbaar en
je bent geen opsporingsambtenaar. Direct melden:

- CSAM: EOKM / Meldpunt Kinderporno, https://www.meldpunt-kinderporno.nl/
- Dreiging voor leven of veiligheid: politie (112 bij acuut gevaar), en dit is
  ook de DSA art. 18-verplichting.

## 4. Het besluit

Drie uitkomsten, en ze hebben alle drie een bericht nodig.

| Besluit | Naar de klant | Naar de melder |
|---|---|---|
| Niets doen | niets | sjabloon C, met reden |
| Inhoud/dienst beperken | **sjabloon B — verplicht** | sjabloon C |
| Account beëindigen | sjabloon B | sjabloon C |

Sjabloon B is de **motivering** die de DSA (art. 17) eist bij élke beperking. Hij
moet zeggen: wat je hebt beperkt, waarom, op welke grond (wet of welk artikel
van de voorwaarden), of het op een melding of op eigen onderzoek berustte, en
hoe de klant bezwaar kan maken. Ook beide berichten vermelden dat men naar de
rechter kan.

**Evenredigheid.** Een phishingpagina op één pad is geen reden om een hele VPS
uit te zetten als de klant bereikbaar is en het binnen een uur weghaalt. Zet de
zwaarste maatregel alleen in als de lichtere aantoonbaar niet werkt, en schrijf
dat op.

## 5. Het register

Eén bestand per zaak, **buiten deze repo** (er staan namen in), bij de rest van
de bedrijfsadministratie:

```
zaaknummer + datum ontvangst
melder (naam, adres) — of "anoniem, categorie X"
wat er gemeld is, en waarom het volgens de melder onrechtmatig is
betrokken VPS / IP / klant
hoogste gebruikte trede (§3) + datum + reden
besluit + datum + motivering
bericht naar klant (datum) / bericht naar melder (datum)
doorgemeld aan een instantie? welke, wanneer
```

Dit register is drie dingen tegelijk: je bewijs dat je prompt hebt gehandeld, de
bron van het transparantieoverzicht (vier tellers, één keer per jaar), en het
enige dat je over een jaar nog kunt raadplegen als dezelfde melder terugkomt.

## 6. Sjablonen

**A — ontvangstbevestiging**

> Onderwerp: Je melding is ontvangen — zaak [nummer]
>
> Bedankt voor je melding. Wij hebben hem geregistreerd onder [nummer] en
> beoordelen hem zo snel mogelijk, uiterlijk binnen 72 uur. Je hoort van ons wat
> wij besluiten en op welke grond.
>
> [Indien van toepassing:] Om je melding te kunnen beoordelen hebben wij nog
> nodig: [ontbrekende elementen uit §1].
>
> Bunk Hosting

**B — motivering aan de klant (DSA art. 17)**

> Onderwerp: Maatregel op je dienst bij Bunk Hosting — [nummer]
>
> Beste [naam],
>
> Wij hebben op [datum] de volgende maatregel genomen: [wat precies — welke VPS,
> welke inhoud, welke beperking].
>
> Reden: [feitelijk wat er is aangetroffen of gemeld]. Grond: [wetsartikel of
> artikel uit onze voorwaarden]. Dit besluit berust op [een melding van een derde
> / eigen onderzoek].
>
> Ben je het er niet mee eens, reageer dan op dit bericht; wij beoordelen het
> opnieuw. Je kunt de zaak ook aan de rechter voorleggen.
>
> Bunk Hosting

**C — besluit aan de melder (DSA art. 16 lid 5)**

> Onderwerp: Besluit op je melding — zaak [nummer]
>
> Wij hebben je melding van [datum] beoordeeld en besloten: [maatregel, of: geen
> maatregel]. Reden: [kort en feitelijk].
>
> Ben je het er niet mee eens, dan kun je de zaak aan de rechter voorleggen.
>
> Bunk Hosting

## 7. Wat hiervan in de voorwaarden hoort

Een verkorte versie van §1 (wat een melding moet bevatten), §2 (de termijnen) en
§3 (hoe ver wordt gekeken, in één alinea). De DSA (art. 14) eist dat je
moderatiebeleid en de manier waarop je besluit in de voorwaarden staan, in
duidelijke taal. Nu staat daar alleen dát je kunt opschorten, niet hoe je
daartoe komt.
