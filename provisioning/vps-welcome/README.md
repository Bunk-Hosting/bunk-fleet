# Welkomstscherm op een klant-VPS

Wat iemand ziet bij zijn **eerste** login op een Bunk-VPS. Daarna niet meer: een
banner die je elke sessie opnieuw begroet is na dag twee ruis waar mensen
doorheen scrollen, terwijl hij de eerste keer wél nuttig is — dan is dit een
verse machine en wil je weten waar je bent beland.

## Wat waar hoort

| bestand | plek op de VPS | rechten |
|---|---|---|
| `welcome` | `/etc/bunk/welcome` | `755` |
| `00-bunk-welcome.sh` | `/etc/profile.d/00-bunk-welcome.sh` | `644` |

`profile.d` en niet `update-motd.d`: dat laatste draait als root zonder
betrouwbare `$HOME`, en het merkteken (`~/.bunk-welcome-seen`) hoort bij de
persoon die inlogt, niet bij de machine. Een tweede account op dezelfde VPS
krijgt zo zijn eigen eerste keer.

Kleur alleen bij een echte terminal: in een pipe of een cronjob leveren
escape-codes alleen rommel op.

## Handmatig installeren

```sh
sudo install -Dm755 welcome              /etc/bunk/welcome
sudo install -Dm644 00-bunk-welcome.sh   /etc/profile.d/00-bunk-welcome.sh
```

## Wat er in staat over onze toegang

Sinds september 2026 noemt het scherm dat er een sleutel van Bunk in de
`authorized_keys` staat, waarvoor die er is, en dat elke sessie via de
webterminal wordt vastgelegd. Dat hoort een klant te weten voordat hij het zelf
ontdekt: die sleutel kan er niet uit zonder de webterminal onbruikbaar te maken,
maar hem onvermeld laten maakt hem erger dan hij is.

**Let op:** zolang dit bestand niet automatisch wordt uitgerold (zie hieronder),
verandert een wijziging hier niets aan de VPSen die al draaien. Die moeten met
de hand bijgewerkt worden, of ze blijven de oude tekst tonen aan wie er nog niet
heeft ingelogd.

## Nog niet automatisch

Staat op de bestaande VPSen, maar nog niet in de template (VM 9000), dus een
nieuwe VPS krijgt het nog niet vanzelf. De template is een read-only base-disk;
dat vraagt een clone-customise-retemplate-ronde, of cloud-init user-data via
`cicustom` — waar dan eerst een snippets-opslag voor moet bestaan. Die tweede
route verdient de voorkeur: dan staat deze inhoud in git in plaats van in een
image die niemand kan reviewen.
