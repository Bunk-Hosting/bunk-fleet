# Installatie – Bunk Hosting VPS-applicatie

De VPS management applicatie voor Bunk Hosting. Draait op `app.bunkhosting.nl`.

## Vereisten

- Docker Engine 24+ en Docker Compose v2
- De [vps-backend](https://github.com/Bunk-Hosting/vps-backend) moet draaien op `api.bunkhosting.nl`

## Productie deployment

In productie wordt de frontend gedeployed via het script op de server:

```bash
ssh administrator@<server-ip>
bash /home/administrator/deploy-frontend.sh
```

Het script gebruikt `-p vps-frontend` zodat containernamen consistent blijven.

### Handmatig deployen

```bash
git clone https://github.com/Bunk-Hosting/vps-frontend.git
cd vps-frontend

docker compose -p vps-frontend -f docker-compose.prod.yml build
docker compose -p vps-frontend -f docker-compose.prod.yml down --remove-orphans
docker compose -p vps-frontend -f docker-compose.prod.yml up -d
```

> **Let op:** `NEXT_PUBLIC_*` variabelen worden ingebakken tijdens de build. Ze staan in `.env.production` en worden automatisch meegenomen.

### Omgevingsvariabelen (.env.production)

| Variabele | Waarde | Uitleg |
|-----------|--------|--------|
| `NEXT_PUBLIC_API_URL` | `https://api.bunkhosting.nl` | Backend REST API URL |
| `NEXT_PUBLIC_WS_URL` | `wss://api.bunkhosting.nl` | WebSocket URL voor SSH-terminal |
| `NEXT_PUBLIC_WEBSITE_URL` | `https://bunkhosting.nl` | Marketingwebsite URL |

### Reverse proxy (Cloudflare Tunnel)

De frontend draait op poort 3001. Cloudflare Tunnel stuurt `app.bunkhosting.nl` door:

```yaml
# ~/.cloudflared/config.yml (tunnel-machine)
ingress:
  - hostname: app.bunkhosting.nl
    service: http://localhost:3001
  - service: http_status:404
```

Cloudflare geeft WebSocket-verbindingen standaard door (nodig voor de SSH-terminal).

## Lokale development

```bash
git clone https://github.com/Bunk-Hosting/vps-frontend.git
cd vps-frontend
npm install
```

Maak `.env.local` aan:

```env
NEXT_PUBLIC_API_URL=http://localhost:8000
NEXT_PUBLIC_WS_URL=ws://localhost:8000
NEXT_PUBLIC_WEBSITE_URL=http://localhost:3000
```

```bash
npm run dev
```

## Routes

| Route | Toegang | Omschrijving |
|-------|---------|-------------|
| `/login` | Publiek | Inloggen |
| `/register` | Publiek | Registreren |
| `/dashboard` | Ingelogd | Dashboard overzicht |
| `/dashboard/vps` | Ingelogd | Eigen VPS-lijst |
| `/dashboard/vps/new` | Ingelogd | Nieuwe VPS aanvragen (Starter/Basic/Pro) |
| `/dashboard/vps/[id]` | Eigenaar/Admin | VPS-detail (start/stop/verwijder) |
| `/dashboard/vps/[id]/terminal` | Eigenaar/Admin | In-browser SSH-terminal via WebSocket |
| `/dashboard/admin` | Admin | Admin-dashboard met statistieken |
| `/dashboard/admin/users` | Admin | Gebruikersbeheer + AVG-conforme Excel-export |
| `/dashboard/admin/vps` | Admin | VPS-beheer (forceer status, start/stop/verwijder) |
| `/dashboard/admin/network` | Admin | IP-pool overzicht + Excel-export |
| `/dashboard/admin/logs` | Admin | Auditlogs met filters en CSV-export |
| `/dashboard/admin/reconcile` | Admin | Reconciliatie DB ↔ vCenter |

## SSH-terminal

De pagina `/dashboard/vps/[id]/terminal` opent xterm.js in de browser. De WebSocket-verbinding loopt via `wss://api.bunkhosting.nl/ws/console/{id}/`. De backend verbindt vervolgens als `bunk-console` servicegebruiker via SSH met de VM, met de private key uit Vault.

- VPS moet status `ACTIVE` hebben
- Knop is uitgeschakeld voor niet-actieve VPS'en

## Updaten

```bash
ssh administrator@<server-ip>
cd /home/administrator/vps-frontend && git pull
bash /home/administrator/deploy-frontend.sh
```
