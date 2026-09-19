# Runbook — datalek

**Waarvoor dit bestaat.** De AVG geeft je 72 uur om een lek bij de Autoriteit
Persoonsgegevens te melden, gerekend vanaf het moment dat je het ontdekt — niet
vanaf het moment dat je begrijpt wat er gebeurd is. Bij een eenmanszaak is
degene die moet melden dezelfde persoon die om drie uur 's nachts het incident
aan het blussen is. Die haalt die 72 uur alleen als het denkwerk vooraf gedaan
is. Dat is dit document.

Lees het één keer rustig door nu er niets aan de hand is. Dat is de hele
investering.

---

## 0. De eerste tien minuten

1. **Stop de blootstelling.** Sleutel intrekken, node dichtzetten
   (`POST /api/v1/beheer/nodes/:id/drain`), container stoppen — wat de bloeding
   stelpt. Nog niets wissen.
2. **Zet de klok.** Schrijf ergens op: datum en tijd waarop je het merkte. Dat
   tijdstip is het begin van de 72 uur en je zult het later precies nodig hebben.
3. **Bewaar bewijs.** Logs van vóór je ingreep zijn het eerste wat verdwijnt.
   `docker logs bf-prod-cp > ~/incident-<datum>.log`, en laat de
   nginx-accesslogs met rust.
4. **Nog niet mailen.** Niet naar klanten, niet naar de AP. Eerst §1.

## 1. Is dit een datalek?

Een datalek is een inbreuk op de beveiliging die leidt tot **vernietiging,
verlies, wijziging, of ongeoorloofde verstrekking van of toegang tot**
persoonsgegevens. Alle vier tellen — een back-up die onherstelbaar weg is, is
net zo goed een lek als een database die op straat ligt.

| Wat er gebeurde | Lek? | Rol van Bunk |
|---|---|---|
| Iemand kon accountgegevens van andere klanten inzien | ja | verwerkingsverantwoordelijke |
| Een klant-VPS of back-up daarvan is uitgelekt | ja | **verwerker** — zie §2 |
| Een klant lekt zelf gegevens uit zijn eigen VPS | nee, niet van jou | geen |
| Een schijf is stuk en de back-up ook | ja (verlies) | hangt af van wiens data |
| Iemand probeerde in te breken en kwam er niet in | nee | geen |
| Een e-mail met klantgegevens naar het verkeerde adres | ja | verwerkingsverantwoordelijke |

Twijfel je? Dan is het een lek tot je het tegendeel hebt vastgesteld, en dan
gaat de klok dus lopen.

## 2. Als het de data van een klant is, ben je verwerker

Dit is het geval dat het snelst misgaat, want het gaat in tegen de reflex om
eerst uit te zoeken hoe erg het is.

Gaat het om de inhoud van een klant-VPS of een back-up daarvan, dan zijn dat
**niet jouw gegevens**. Je verwerkt ze voor die klant. Artikel 33 lid 2 zegt
dan maar één ding: **informeer die klant onverwijld.** Niet binnen 72 uur —
onverwijld. Jij meldt niet bij de AP; dat doet de klant, en die kan dat alleen
als hij het op tijd weet.

Gebruik sjabloon B in §6. Stuur hem ook als je nog niet alles weet; dat mag, en
"we weten nog niet precies wat" is informatie waar een klant iets mee kan.

## 3. Moet het naar de AP?

Melden binnen 72 uur, **tenzij** het onwaarschijnlijk is dat het lek een risico
oplevert voor de betrokkenen. Die uitzondering is smaller dan hij klinkt.

Geen melding nodig, waarschijnlijk:
- gegevens waren versleuteld met een sleutel die niet mee is gelekt;
- het ging om gegevens die toch al openbaar waren;
- het bleef binnen één persoon die er beroepsmatig bij mocht.

Wel melden, waarschijnlijk:
- e-mailadressen in combinatie met wat dan ook;
- wachtwoordhashes, sessietokens, API-tokens, SSH-sleutels;
- betaalgegevens of factuurgegevens;
- alles waarbij je niet kunt uitsluiten dat iemand het heeft ingezien.

Meld je niet, dan leg je in het register (§5) vast **waarom niet**. Dat is geen
formaliteit: artikel 33 lid 5 eist dat je ook de niet-gemelde lekken
documenteert, en dat register is het enige bewijs dat je de afweging hebt
gemaakt in plaats van hem te hebben overgeslagen.

**Melden gaat hier:**
https://www.autoriteitpersoonsgegevens.nl/themas/beveiliging/datalekken/datalek-melden

Loop dat formulier nú een keer door zonder te verzenden, zodat je weet wat het
vraagt. Wat je in elk geval bij de hand moet hebben: wanneer het gebeurde,
wanneer je het ontdekte, wat voor gegevens, hoeveel mensen ongeveer, wat de
gevolgen kunnen zijn, en wat je hebt gedaan.

Weet je het nog niet allemaal? **Meld alvast.** Een melding aanvullen mag; te
laat melden niet.

## 4. Moeten de betrokkenen het horen?

Alleen bij een **hoog** risico — identiteitsfraude, financiële schade,
blootstelling van iets gevoeligs. Dan informeer je ze zelf, in gewone taal
(sjabloon A). Niet nodig als de gegevens versleuteld waren, of als je het
risico intussen hebt weggenomen.

Twijfel: doe het wel. Een klant die het van jou hoort is boos; een klant die het
ergens anders hoort is weg.

## 5. Het register

Elk lek komt in het register. Ook de kleine. Ook die je niet gemeld hebt.

Het register staat **niet in deze repo** — er staan namen en adressen in. Houd
het bij op de plek waar ook de andere bedrijfsadministratie staat, als één
bestand per incident:

```
datum + tijd van ontdekking
datum + tijd van het incident zelf (voor zover bekend)
wat er gebeurde, feitelijk
welke gegevens, van hoeveel mensen
rol: verantwoordelijke of verwerker
gevolgen / mogelijke gevolgen
wat er is gedaan om het te stoppen
gemeld bij de AP? ja (datum, referentie) / nee (waarom niet)
betrokkenen geïnformeerd? ja (datum) / nee (waarom niet)
klant geïnformeerd (bij verwerkerschap)? datum
wat er structureel is veranderd zodat het niet weer gebeurt
```

Die laatste regel is de enige die er over een jaar nog toe doet.

## 6. Sjablonen

**A — aan een betrokkene (hoog risico)**

> Onderwerp: Belangrijk: een beveiligingsincident bij Bunk Hosting
>
> Beste [naam],
>
> Op [datum] hebben wij vastgesteld dat [feitelijk wat er gebeurde]. Daarbij
> zijn de volgende gegevens van jou betrokken: [opsomming].
>
> Wat dit voor je kan betekenen: [concreet, geen geruststelling die je niet kunt
> waarmaken].
>
> Wat wij hebben gedaan: [maatregelen, met tijdstip].
>
> Wat wij je aanraden om te doen: [concreet — wachtwoord wijzigen, sleutel
> vervangen, alert op phishing].
>
> Vragen kun je stellen via [adres]. Je kunt dit incident ook melden bij de
> Autoriteit Persoonsgegevens.
>
> [naam], Bunk Hosting

**B — aan een klant wiens data je als verwerker hebt (art. 33 lid 2)**

> Onderwerp: Beveiligingsincident dat gegevens op je VPS raakt
>
> Beste [naam],
>
> Wij melden je dit onverwijld, ook omdat je als verwerkingsverantwoordelijke
> zelf moet beoordelen of hier een melding bij de Autoriteit Persoonsgegevens
> aan de orde is, en daar 72 uur voor hebt vanaf dit bericht.
>
> Wat wij weten: [feitelijk]. Welke van jouw systemen: [VPS-naam, node,
> periode]. Wat wij nog niet weten: [eerlijk].
>
> Wat wij hebben gedaan: [maatregelen, met tijdstip].
>
> Wij helpen je met alles wat je voor je eigen beoordeling nodig hebt — logs,
> tijdlijn, technische details. Vraag ernaar via [adres].
>
> [naam], Bunk Hosting

## 7. Achteraf

Binnen een week: schrijf op wat er structureel is veranderd. Geen "beter
opletten" — een regel, een test, een controle die het volgende keer tegenhoudt.
Zet die verandering in de repo, met een verwijzing naar het incident. Als er
niets te veranderen viel, schrijf dan op waarom niet.
