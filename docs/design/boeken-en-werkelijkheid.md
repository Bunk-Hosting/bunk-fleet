# Design — de boeken laten kloppen met de werkelijkheid

*Status: voorstel. Geschreven 2026-09-17 tegen commit `1b5a2d7`. Elke bewering
over "vandaag" is tegen het draaiende systeem gecontroleerd, niet uit de code
afgeleid.*

Twee dingen die de vloot op termijn scheef laten lopen. Ze staan in één document
omdat ze dezelfde vorm hebben: het control plane houdt een administratie bij die
niemand vergelijkt met wat er werkelijk op de hardware gebeurt. De ene keer gaat
dat over of een VPS bestaat, de andere keer over hoeveel regels die administratie
mag worden.

Geen van beide is vandaag dringend. Beide zijn vandaag goedkoop op te lossen en
duur om over een jaar op te lossen.

---

## 1. Er wordt afgerekend zonder dat iemand kijkt of het bestaat

### Wat er nu gebeurt

Een VPS wordt `:active` op het woord van de agent. Vanaf dat moment schrijft
`Subscriptions.settle_due/1` er maandelijks voor af en legt `Billing.meter_batch`
er elk uur verbruik voor vast. Beide lopen uitsluitend over wat het control plane
zelf in de database heeft staan.

De reconciler doet elke tick negen dingen — vastgelopen aanmaakopdrachten
laten falen, niet-opgehaalde reserveringen terugnemen, wezen-afschrijvingen
terugbetalen, mislukte verwijderingen opnieuw proberen, verbruik meten,
abonnementen afrekenen — maar **geen daarvan kijkt naar de node zelf**. Er is geen
enkele plek in de code waar het control plane vraagt: bestaat VPS X nog, en
draait hij?

Dat is met opzet zo gebouwd voor een federatiemodel waarin nodes van derden
waren en de control plane ze niet vertrouwde. Dat model is op 2026-09-09
losgelaten; er is geen uitbetaling aan operators meer in de code. De bevinding
uit de audit van juli ("de control plane rekent af en betaalt uit op wat de agent
zegt") is daarmee voor de helft achterhaald, en de andere helft is van kleur
veranderd: het gaat niet meer om een operator die liegt, maar om het feit dat
niemand het merkt als de administratie en de werkelijkheid uit elkaar lopen.

### Waarom dat een probleem is

Er zijn twee richtingen en ze doen allebei pijn.

**De klant betaalt voor niets.** Een VM die buiten Bunk om verdwijnt — een
handmatige `qm destroy`, een herinstallatie van de host, een schijf die sterft —
laat een abonnement achter dat elke maand blijft afschrijven. Niets merkt het.
De klant merkt het wel, en dat is het slechtst denkbare moment om erachter te
komen.

**Bunk raakt capaciteit kwijt.** Een VM die het control plane voor verwijderd
houdt maar die nog draait, eet echt geheugen op de node. Sinds de capaciteit
wordt afgeleid uit wat de node meldt (commit `03aeeba`) komt dat wel in de
cijfers terecht, maar zonder naam en zonder reden: de node biedt minder aan en
niemand weet waarom.

### Wat ik voorstel

**Stap 1 — een statuscommando dat al bestaat, periodiek gebruiken.** De agent
kan `StatusVM` al; het provider-contract heeft het en de ESXi- en Proxmox-kant
implementeren het allebei. Er is alleen geen opdrachtsoort die het aanroept.
Voeg `:status` toe aan de commando's, en laat de reconciler op een rustige
cadans (eens per uur, gespreid over de vloot) de VPS'en langsgaan die `:active`
of `:stopped` heten.

Let op de valkuil uit `CLAUDE.md`: `CommandController.result_attrs/1` is een
allow-list. Een nieuwe opdrachtsoort die een veld terugmeldt moet daar ook in,
anders legt het control plane het resultaat vast en gooit de inhoud stil weg.

**Stap 2 — verschil vastleggen, niet meteen handelen.** Een VPS die de node niet
kent krijgt een `drift_detected_at` en een melding in het beheerpaneel. Niet
automatisch opzeggen en niet automatisch terugbetalen: een node die net herstart
of een API die even hapert mag geen abonnement beëindigen. De eerste versie
observeert en meldt; wat eraan gedaan wordt blijft een mens.

**Stap 3 — pas daarna eventueel automatisch.** Als na een week blijkt dat de
melding betrouwbaar is, kan een VPS die drie opeenvolgende controles onbekend is
automatisch op `:failed` met terugbetaling van de lopende maand. Dat is een aparte
beslissing, met een aparte test, en niet iets om in stap 1 mee te nemen.

### Wat het kost

Een opdrachtsoort, een veld op `vpses`, een reconcilerstap en een regel in het
paneel. De agent verandert niet. De grootste zorg is niet de code maar de cadans:
elke controle is een opdracht die de node moet ophalen en beantwoorden, dus eens
per uur gespreid, niet elke tick over de hele vloot.

---

## 2. `usage_records` groeit zonder plafond

### Wat er nu staat

Vandaag: **406 rijen, 1256 kB**, van 1 juli tot 17 september, met één tot twee
VPS'en. Er wordt per actieve VPS per uur één rij geschreven.

Dat is de rekensom die telt:

| actieve VPS'en | rijen per jaar |
|---|---|
| 2 | ~17.500 |
| 50 | ~440.000 |
| 500 | ~4,4 miljoen |

Er is geen bewaartermijn, geen samenvatting per dag, en geen partitionering. De
verbruiksoverzichten lezen de ruwe rijen.

### Waarom dat een probleem is

Niet vanwege de schijfruimte — die is goedkoop. Het probleem is dat elke query
die "hoeveel heeft deze klant deze maand verbruikt" beantwoordt over een tabel
gaat die maandelijks groeit en nooit krimpt, terwijl het antwoord voor elke
afgesloten dag nooit meer verandert.

### Wat ik voorstel

**Stap 1 — een dagtotaal per VPS.** Een tabel `usage_daily` met één rij per VPS
per dag, geschreven door een reconcilerstap die de dag ervoor samenvat zodra die
voorbij is. De overzichten lezen de dagtotalen voor afgesloten dagen en de ruwe
rijen alleen voor vandaag.

**Stap 2 — een bewaartermijn op de ruwe rijen.** Zodra een dag is samengevat en
gecontroleerd, mogen de uurrijen van die dag na een marge weg. Negentig dagen is
een verdedigbare marge: lang genoeg om een factuur na te rekenen, kort genoeg om
de tabel klein te houden. Dat is ook een AVG-argument — verbruiksgegevens zijn
persoonsgegevens en "we bewaarden alles" is geen bewaarbeleid.

**Stap 3 — partitioneren, maar pas als het nodig is.** Met een dagtotaal en een
bewaartermijn blijft de ruwe tabel begrensd op negentig dagen. Partitioneren
lost dan niets meer op wat die twee niet al opgelost hebben, en het maakt elke
migratie erna ingewikkelder. Niet doen tot de cijfers zeggen dat het moet.

### De volgorde is niet vrijblijvend

Eerst samenvatten, dan pas opruimen. Andersom verlies je gegevens waarvan je nog
niet hebt bewezen dat je ze kunt reproduceren. En de samenvatting moet een tijd
naast de ruwe rijen meelopen zodat je kunt controleren dat de totalen gelijk
zijn, vóór er iets wordt weggegooid.

---

## Wat ik niet voorstel

**De agent laten tekenen voor zijn meldingen.** Cryptografische attestatie van
provisioning-resultaten hoorde bij het federatiemodel. Zolang de nodes van Bunk
en van Julian zijn, beschermt het tegen een aanvaller die de node al bezit — en
die kan dan toch al bij de VPS'en zelf. De kosten (sleutelbeheer, rotatie, een
tweede manier waarop een node kan falen) wegen daar niet tegenop.

**Automatisch opzeggen bij het eerste verschil.** Zie stap 2 hierboven. Een
controle die zelf storingen kan veroorzaken is erger dan geen controle.
