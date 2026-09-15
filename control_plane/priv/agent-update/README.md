# Automatisch bijwerken van de agent

Een node haalt zijn eigen binary op bij de control plane, controleert de hash en
vervangt zichzelf alleen als die klopt. De oude binary blijft staan tot de nieuwe
bewezen draait; komt de service niet op, dan zet de updater het terug.

## Op een nieuwe node

`install.sh` zet dit er vanzelf op. Je hoeft niets te doen.

## Op een bestaande node

```sh
curl -fsSL https://app.bunkhosting.nl/agent-update.sh | sh
```

Dat installeert het script, de service en de timer, en draait de controle meteen
één keer.

## Met de hand bijwerken

```sh
/usr/local/bin/bunk-agent-update
```

Zit de node al op de juiste build, dan zegt hij dat en stopt hij.

## Wanneer draait het

Elke nacht rond vier uur, met een uur speling zodat niet elke node tegelijk
dezelfde binary komt ophalen. Stond de machine uit, dan haalt systemd de run na
het opstarten alsnog in.
