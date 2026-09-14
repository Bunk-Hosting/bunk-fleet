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

## Nog niet automatisch

Staat op de bestaande VPSen, maar nog niet in de template (VM 9000), dus een
nieuwe VPS krijgt het nog niet vanzelf. De template is een read-only base-disk;
dat vraagt een clone-customise-retemplate-ronde, of cloud-init user-data via
`cicustom` — waar dan eerst een snippets-opslag voor moet bestaan. Die tweede
route verdient de voorkeur: dan staat deze inhoud in git in plaats van in een
image die niemand kan reviewen.
