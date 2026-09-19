# Runbook — vordering of verzoek van een autoriteit

**Waarvoor dit bestaat.** Bij een eenmanszaak beslist de eigenaar, alleen,
waarschijnlijk aan de telefoon en onder tijdsdruk. Dat is het hele risico. De
kans dat het gebeurt is bij een handvol klanten klein, maar de eerste keer dat
het gebeurt is er geen tijd om het dan te bedenken.

Er is één regel die alle andere draagt: **niets verstrekken op een telefoontje.**

---

## 1. Wat je kunt verwachten

| Vorm | Wie | Waarvoor | Drempel |
|---|---|---|---|
| Vordering identificerende gegevens (art. 126nc Sv) | opsporingsambtenaar | naam, adres, e-mail, betaalgegevens | laag |
| Vordering andere gegevens (126nd/126ng Sv) | officier van justitie | verkeersgegevens, gebruiksgegevens | midden |
| Vordering inhoud (126ng lid 2 Sv) | officier, met machtiging rechter-commissaris | wat er op de schijf staat | hoog |
| Doorzoeking / inbeslagname | politie, met machtiging | de machine zelf | hoog |
| Civiele sommatie | advocaat, BREIN, rechthebbende | verwijderen, gegevens afgeven | **geen bevoegdheid**, wel een deadline |

Wetteksten: https://wetten.overheid.nl/BWBR0001903/ (Sv, art. 126nc–126ng).

Een civiele sommatie is géén vordering. Je hoeft er niet aan te voldoen, maar je
moet er wel iets mee: negeren kan je de vrijstelling kosten als er echt iets
onrechtmatigs staat. Behandel hem als een misbruikmelding
([abuse.md](abuse.md)), niet als dit document.

## 2. De zes stappen

1. **Schriftelijk laten bevestigen.** Altijd, zonder uitzondering. "Stuurt u het
   even per mail, dan pak ik het meteen op" is een volledig normale reactie en
   geen tegenwerking. Bel bij twijfel terug via het algemene nummer van de
   instantie, niet via het nummer dat je gebeld heeft.
2. **Controleren wat er staat.** Wie vordert, op welke wettelijke grondslag,
   welk artikel, welke gegevens precies, over welke periode, en of er een
   geheimhoudingsplicht bij zit. Staat de grondslag er niet bij, vraag ernaar.
3. **Alleen verstrekken wat er letterlijk gevorderd wordt.** Een vordering om
   accountgegevens is geen vordering om een schijfkopie. Is de vordering ruimer
   dan de grondslag toelaat, of onduidelijk, vraag dan om verduidelijking of
   laat er een advocaat naar kijken vóór je iets stuurt. Te veel verstrekken is
   zelf een datalek.
4. **Vastleggen in het register** (§3), ook als je niets verstrekt.
5. **De klant informeren, tenzij het niet mag.** De standaardregel is: je
   informeert de klant. Zit er een geheimhoudingsplicht bij, dan niet — en dan
   noteer je in het register wanneer die vervalt, zodat je het alsnog kunt doen.
   Deze regel vooraf vastleggen is het verschil tussen een houding en een
   impuls.
6. **De node-eigenaar.** Staat de betrokken VPS op een node bij iemand anders
   thuis, dan gaat de politie naar diens **woonadres**. Zie §4.

## 3. Het register

Eén regel per verzoek, **buiten deze repo**, bij de bedrijfsadministratie:

```
datum ontvangst + hoe binnengekomen
afzender (instantie, naam, functie)
wettelijke grondslag + artikel
wat er gevorderd is, precies
wat er verstrekt is, precies (of: niets, en waarom)
datum verstrekking + door wie
geheimhoudingsplicht? tot wanneer
klant geïnformeerd? datum / nee, want [reden]
```

Dit register is tegelijk het transparantieoverzicht: één keer per jaar vier
tellers publiceren (meldingen ontvangen/gehonoreerd, verzoeken
ontvangen/gehonoreerd). Bij de huidige omvang staat daar vier keer nul, en een
pagina die dat eerlijk zegt is het sterkste dat een kleine hoster kan
publiceren.

## 4. Als er bij een node-eigenaar wordt aangebeld

Niet elke node staat bij Bunk. Wie een node draait, moet dit vooraf weten:

- **Bel Bunk direct.** Voordat er iets wordt afgegeven, en voordat er iets
  wordt aangezet of uitgezet.
- **Vraag om legitimatie en om de machtiging op papier.** Ook aan de deur.
- **Geef niets af wat niet gevorderd is.** Op die machine staan ook de VPS'en
  van andere klanten; die vallen niet onder een vordering die over één klant
  gaat. Zeg dat, en zeg het ter plekke.
- **Zet niets uit en wis niets.** Dat kan als het wegmaken van bewijs worden
  gezien, ook als het goedbedoeld is.
- **Schrijf op wat er is gebeurd**, dezelfde dag nog: wie, wanneer, wat
  meegenomen of gevraagd.

Dit hoort in de afspraak met elke node-eigenaar te staan, samen met de
afspraken over abuse-mail en over zijn rol als sub-verwerker.

## 5. Wat je niet doet

- Gegevens verstrekken op basis van een telefoontje, een WhatsApp, of een mail
  zonder grondslag.
- Meer verstrekken dan gevorderd, "voor de zekerheid" of om behulpzaam te zijn.
- Een klant afsluiten omdat er een vordering over hem binnenkomt. Een vordering
  is geen veroordeling en geen grond uit je voorwaarden.
- De klant informeren terwijl er een geheimhoudingsplicht ligt.
