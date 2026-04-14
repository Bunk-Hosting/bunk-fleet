# vps-frontend

Next.js dashboard voor het Bunk Hosting VPS-platform. Draait op `app.bunkhosting.nl`.

Zie [installation.md](installation.md) voor installatie- en deploymentinstructies.

## Tech stack

| Technologie | Versie | Doel |
|---|---|---|
| Next.js | 14 | React framework (App Router) |
| TypeScript | 5 | Type-veiligheid |
| Tailwind CSS | 3 | Styling |
| shadcn/ui + Radix UI | — | UI-componenten |
| xterm.js | 5 | In-browser SSH-terminal |
| axios | 1.7 | HTTP-client |

## Architectuur

```
bunkhosting.nl         — marketingwebsite (apart project)
app.bunkhosting.nl     — dit project (Next.js dashboard)
api.bunkhosting.nl     — REST API + WebSocket (vps-backend)
```

Verkeer loopt via Cloudflare Tunnel → Next.js standalone server op poort 3001.

## Routes

| Route | Toegang | Omschrijving |
|---|---|---|
| `/login` | Publiek | Inloggen |
| `/register` | Publiek | Registreren |
| `/dashboard` | Ingelogd | Overzicht |
| `/dashboard/vps` | Ingelogd | Eigen VPS-lijst |
| `/dashboard/vps/new` | Ingelogd | Nieuwe VPS aanvragen (Starter/Basic/Pro) |
| `/dashboard/vps/[id]` | Eigenaar/Admin | VPS-detail (start/stop/verwijder) |
| `/dashboard/vps/[id]/terminal` | Eigenaar/Admin | In-browser SSH-terminal via WebSocket |
| `/dashboard/admin` | Admin | Admin-dashboard met statistieken |
| `/dashboard/admin/users` | Admin | Gebruikersbeheer + AVG-conforme CSV-export |
| `/dashboard/admin/vps` | Admin | VPS-beheer (forceer status, start/stop/verwijder) |
| `/dashboard/admin/network` | Admin | IP-pool overzicht + CSV-export |
| `/dashboard/admin/logs` | Admin | Auditlogs met filters en CSV-export |
| `/dashboard/admin/reconcile` | Admin | Reconciliatie DB ↔ vCenter |

## Omgevingsvariabelen

| Variabele | Uitleg |
|---|---|
| `NEXT_PUBLIC_API_URL` | HTTPS URL van de backend API (bijv. `https://api.bunkhosting.nl`) |
| `NEXT_PUBLIC_WS_URL` | WebSocket URL voor de SSH-terminal (bijv. `wss://api.bunkhosting.nl`) |
| `NEXT_PUBLIC_WEBSITE_URL` | URL van de marketingwebsite |

> `NEXT_PUBLIC_*` variabelen worden ingebakken tijdens de Docker-build en moeten als `--build-arg` meegegeven worden.
