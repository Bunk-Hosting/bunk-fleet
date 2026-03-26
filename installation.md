# Installatie – Bunk Hosting VPS-applicatie

De VPS management applicatie voor Bunk Hosting. Draait op `app.bunkhosting.nl` en biedt het dashboard voor gebruikers en admins om VPS'en te beheren.

## Vereisten

- Node.js 20+ (of Docker)
- De [vps-backend](https://github.com/<jouw-org>/vps-backend) moet draaien

## Optie A – Docker (aanbevolen voor productie)

### Stap 1 – Repository klonen

```bash
git clone https://github.com/<jouw-org>/vps-frontend.git
cd vps-frontend
```

### Stap 2 – Omgevingsvariabelen instellen

Maak `.env.local` aan:

```env
NEXT_PUBLIC_API_URL=https://api.bunkhosting.nl
NEXT_PUBLIC_WS_URL=wss://api.bunkhosting.nl
NEXT_PUBLIC_WEBSITE_URL=https://bunkhosting.nl
```

| Variabele | Uitleg |
|-----------|--------|
| `NEXT_PUBLIC_API_URL` | URL van de backend REST API |
| `NEXT_PUBLIC_WS_URL` | WebSocket URL van de backend (voor VPS console) |
| `NEXT_PUBLIC_WEBSITE_URL` | URL van de marketingwebsite (voor Home/Producten links in navbar) |

### Stap 3 – Docker image bouwen

```bash
docker build -t bunk-hosting-app:latest \
  --build-arg NEXT_PUBLIC_API_URL=https://api.bunkhosting.nl \
  --build-arg NEXT_PUBLIC_WS_URL=wss://api.bunkhosting.nl \
  --build-arg NEXT_PUBLIC_WEBSITE_URL=https://bunkhosting.nl \
  .
```

> **Let op:** `NEXT_PUBLIC_*` variabelen worden ingebakken tijdens de build. Ze moeten als build-arg meegegeven worden.

### Stap 4 – Container starten

```bash
docker run -d \
  --name bunk-hosting-app \
  --restart unless-stopped \
  -p 3001:3000 \
  bunk-hosting-app:latest
```

### Stap 5 – Reverse proxy instellen

Stel een reverse proxy in die `app.bunkhosting.nl` doorstuurt naar poort 3001.

**Voorbeeld met Cloudflare Tunnel:**

```yaml
# ~/.cloudflared/config.yml
ingress:
  - hostname: app.bunkhosting.nl
    service: http://localhost:3001
  - service: http_status:404
```

**Voorbeeld met nginx:**

```nginx
server {
    listen 80;
    server_name app.bunkhosting.nl;

    location / {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
```

### Stap 6 – Verificatie

Open `https://app.bunkhosting.nl/login` in je browser. Je zou moeten zien:

- Login pagina met e-mail en wachtwoord velden
- Navbar met links naar `bunkhosting.nl` (Home, Producten)
- Na inloggen: dashboard met VPS overzicht

## Optie B – Lokale development

### Stap 1 – Repository klonen en dependencies installeren

```bash
git clone https://github.com/<jouw-org>/vps-frontend.git
cd vps-frontend
npm install
```

### Stap 2 – Omgevingsvariabelen instellen

Maak `.env.local` aan:

```env
NEXT_PUBLIC_API_URL=http://localhost:8000
NEXT_PUBLIC_WS_URL=ws://localhost:8000
NEXT_PUBLIC_WEBSITE_URL=http://localhost:3000
```

### Stap 3 – Development server starten

```bash
npm run dev -- -p 3001
```

De applicatie draait nu op `http://localhost:3001`.

> **Tip:** Start de volledige stack lokaal:
> - Backend: `http://localhost:8000` (via `docker compose up` in vps-backend)
> - Website: `http://localhost:3000` (via `npm run dev` in bunkhosting-website)
> - VPS-app: `http://localhost:3001` (deze applicatie)

### Stap 4 – Docker Compose (alternatief)

```bash
docker compose up
```

Dit start de development server met hot-reload op poort 3001.

## Optie C – Productie build zonder Docker

### Stap 1 – Dependencies installeren en bouwen

```bash
npm ci
NEXT_PUBLIC_API_URL=https://api.bunkhosting.nl \
NEXT_PUBLIC_WEBSITE_URL=https://bunkhosting.nl \
npm run build
```

### Stap 2 – Standalone server starten

```bash
cd .next/standalone
PORT=3001 node server.js
```

Stel een reverse proxy in zoals beschreven in stap 5 van Optie A.

## Routes

| Route | Beschrijving | Toegang |
|-------|-------------|---------|
| `/` | Redirect naar `/login` | Publiek |
| `/login` | Inloggen | Publiek |
| `/register` | Registreren | Publiek |
| `/dashboard` | Dashboard overzicht | Ingelogd |
| `/dashboard/vps` | Mijn VPS'en | Ingelogd |
| `/dashboard/vps/new` | Nieuwe VPS aanvragen | Ingelogd |
| `/dashboard/vps/[id]` | VPS details (start/stop/verwijder) | Eigenaar of admin |
| `/dashboard/vps/[id]/console` | In-browser terminal (WebSocket SSH) | Eigenaar of admin |
| `/dashboard/admin` | Admin dashboard | Admin |
| `/dashboard/admin/users` | Gebruikersbeheer | Admin |
| `/dashboard/admin/vps` | VPS beheer | Admin |
| `/dashboard/admin/logs` | Auditlogs | Admin |

## Overzicht architectuur

```
bunkhosting.nl (bunkhosting-website, apart project)
├── / ..................... Homepage
└── /products ............. Pakketten overzicht

app.bunkhosting.nl (deze applicatie)
├── /login ................ Inloggen
├── /register ............. Registreren
├── /dashboard ............ Overzicht
├── /dashboard/vps ........ VPS lijst + beheer
└── /dashboard/admin ...... Admin panel

api.bunkhosting.nl (vps-backend, apart project)
└── /api/v1/ .............. REST API
```

## Updaten

```bash
git pull
docker build -t bunk-hosting-app:latest \
  --build-arg NEXT_PUBLIC_API_URL=https://api.bunkhosting.nl \
  --build-arg NEXT_PUBLIC_WS_URL=wss://api.bunkhosting.nl \
  --build-arg NEXT_PUBLIC_WEBSITE_URL=https://bunkhosting.nl \
  .
docker stop bunk-hosting-app
docker rm bunk-hosting-app
docker run -d \
  --name bunk-hosting-app \
  --restart unless-stopped \
  -p 3001:3000 \
  bunk-hosting-app:latest
```
