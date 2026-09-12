# Bunk-Fleet — Code-Quality Review

Craftsmanship/maintainability review (2026-06-29) across control plane (Elixir), agent (Go), frontend (Next.js). Overall both halves are already strong — the Go agent is genuinely senior-grade (consistent `%w` wrapping, compile-time interface assertions, context deadlines, testable pure helpers); the frontend has **zero `any`/`as any`** in `src`; the control-plane contexts are well-factored with crisp *why* comments on the tricky machinery (advisory locks, reconciler crash policy, divide-once billing math, FOR UPDATE idempotency). The findings are about going from "good" to "lived-in by a staff engineer."

## Fixed this round
- Frontend: deleted the byte-identical dead duplicate `src/hooks/use-toast.ts` (0 importers); unified the two euro formatters (`formatPrice` now delegates to `formatEuro`, so `€ 5,00` renders consistently everywhere).
- Agent: ESXi `power()` now rejects an unknown op instead of nil-derefing `task.Wait` (correctness foot-gun).

## Prioritized cleanup backlog (next quality round)

### Control plane (Elixir)
1. **[HIGH] Two parallel customer UIs.** `/dashboard/*` (CustomerDashboardLive et al.) and the legacy `/app/*` (PortalLive/HostLive/TopupLive) both serve the same customer features; `signed_in_path` even points at the legacy `/app`. Note: with the nginx edge routing `/` to the Next.js frontend, **the CP's LiveView customer UIs are not publicly reachable at all** — strong candidates for removal. Decide the canonical stack, delete the other, repoint `signed_in_path`. `HostLive.mount` also re-implements role promotion (dup of `HostController.activate`).
2. **[HIGH] Extract repeated edge helpers.** `error(conn, status, msg)` is copy-pasted in 4 controllers; `bearer_token/1` in 3 plugs + a controller (and they *disagree* on trim/empty); `unauthorized/1` in 3 plugs. → a `ControlPlaneWeb.ApiResponse` (imported in `control_plane_web.ex`) + a `Plugs.Bearer` helper.
3. **[HIGH] Capacity-restore changeset duplicated 5×** (provisioning.ex ×4 + fleet.ex) and its inverse in scheduler.ex. → `Node.add_capacity_changeset/4` + `subtract_capacity_changeset/4`. This is the highest-value contexts extraction — capacity math should be defined once.
4. **[HIGH] IPv4 int/validation math duplicated 3×** (overlay.ex, ip_pool.ex identical; node.ex its own strict variant). → one `ControlPlane.Net` with the strict octet check used everywhere.
5. **[HIGH, easy] Dead code:** `Fleet.record_heartbeat/2`, `Provisioning.pending_commands_for_node/1` (0 callers — confirmed), `UserAuth.on_mount(:mount_current_user|:redirect_if_authenticated)` + `redirect_if_user_is_authenticated/2` (unreferenced), empty `scope "/api"`, Node fields `enroll_token_hash`/`public_key` (cast+migrated, never used), `delete_in_flight?/1` (== `power_in_flight?(_, :delete)`).
6. **[MED] Datetime-window parsing** duplicated across billing/operator/admin controllers → `ControlPlaneWeb.TimeWindow`.
7. **[MED] Serializers + region/tier resolution + install-command** duplicated across operator/admin/vps controllers (`node_json`, `vps_json`, `region_code` ×4, `resolve_region` ×4, `install_command` ×2) → small `*JSON`/`Serializers` + `Fleet.fetch_region/1` + `InstallCommand` helper.
8. **[MED] Changeset-error formatting** has 3 different implementations → one `ChangesetErrors.to_map/1`.
9. **[MED] Inconsistent API error language/shape** — machine codes vs English sentences vs Dutch; Dutch UI strings baked into the `Credits` context. Standardize on snake_case machine codes; move user-facing Dutch to the web/i18n layer.
10. **[MED→LOW] Public-context hygiene:** add `@spec` to the public Fleet/Provisioning/Billing/Credits/Accounts API; one shared `ControlPlane.Time.now/0` (defined 3×); a `Repo.advisory_xact_lock/1` helper; normalize the `attrs[:x] || attrs["x"]` dual-key dance once at the `create_vps/1` boundary; re-attach two misplaced doc comments (provisioning.ex mark_vps_deleted/cancel_and_release).

### Agent (Go)
- **[MED] `parseVMID(id)` helper** — the `strconv.Atoi` + error-wrap block is copy-pasted 6× in proxmox.go; `withClient(ctx, fn)` for the connect+defer-logout boilerplate repeated 6× in esxi.go.
- **[MED] Split `main.go handleCommand`** (~127-line switch) into `handleProvision`/`handleDelete`/`handlePower`.
- **[MED] Strip external-backlog ID prefixes** from comments (`H4:`, `R1:`, `R5:`, `R3:`, `H3`, `C1`) — keep the rationale, drop the labels (noise to a future reader).
- **[MED] Stale comments:** config.go:66 + main.go:138 say hypervisor is "only proxmox" — ESXi is fully supported. proxmox.go:56-72 has a doc comment stranded above `safeBridge` instead of `New`.
- **[LOW] `esxi.go isNotFound`** prefer `errors.As`; `Overlay.HubIP` decoded but unused; `persistedState.WGPublicKey`/`OverlayCIDR` persisted but never read.

### Frontend (Next.js)
- **[HIGH] Extract a `useApiData(fetcher)` hook** — 21 pages hand-roll the same loading/error/try-catch (73 state decls). Biggest maintainability win.
- **[HIGH] Unify `api.ts` return conventions** — most methods return `{data}`, but `hostApi.*` return raw, and `vpsApi.delete/start/stop` + `authApi.totp.*` return the bare AxiosResponse. Pick one (recommend: always unwrapped domain data).
- **[HIGH] Remove dead email-OTP login flow** (~130 lines in login/page.tsx) — `authApi.login` never returns `otp_required`, so the `"otp"` step, `handleOtp`, the countdown, etc. are unreachable. (Keep the honeypot block — intentional security trap.)
- **[MED] Dead VPS sudo-password UI** (`vpsApi.credentials` hardcodes null) + extract a `<ConfirmDialog>` (Start/Stop/Delete dialogs are 3 near-clones, repeated again in beheer).
- **[MED] `adminApi` `/beheer/*`** surface 404s on bunk-fleet — quarantine or implement (parity scaffolding).
- **[LOW] Dead exports** `types.ts JwtPayload`, `api.ts loginTotp`/`resendVerification`; named `LoginResult` type instead of the twice-inlined cast; pick one comment language (safeNext is commented in both NL and EN).


---

# Ronde 2 — 2026-09-12

Alles uit de backlog hierboven is nagelopen. Wat nu nog open staat, staat onderaan.

## Afgehandeld sinds ronde 1

**Control plane.** De dubbele klant-UI is weg (de LiveView-portalen bestaan niet
meer). `ControlPlaneWeb.ApiResponse`, `Plugs.Bearer`, `ControlPlaneWeb.TimeWindow`,
`ControlPlane.Net` en `Node.add_capacity/2` bestaan en worden overal gebruikt.
`ControlPlane.Locks` geeft de vijf advisory-lockplekken een naam in plaats van een
getal. `Fleet.record_heartbeat/2` en `Provisioning.pending_commands_for_node/1` zijn
verdwenen; `delete_in_flight?/1` is opgegaan in `in_flight?/2` en het verschil met
`provision_in_flight?/1` — alleen `:delivered` telt daar, want een provision die nog
in de wachtrij staat heeft nog niets gemaakt — staat nu opgeschreven in plaats van
dat het op een vergissing lijkt. `provisioning.ex` is gesplitst in
`Provisioning` / `Provisioning.Results` / `Provisioning.Reservations`.
`UserAuth.redirect_if_user_is_authenticated/2` was niet dood maar niet aangesloten;
hij hangt nu aan /login, /login/mfa en /register.

**Agent.** `parseVMID` vervangt zes kopieën van dezelfde Atoi-en-wrap.
`handleCommand` is een dispatch van vijf regels geworden, met `handleProvision`,
`adoptExisting`, `handleDelete`, `handlePower` en `payloadVMID` eronder; de
`command`-struct draagt de vijf argumenten die anders door elke exit van elke
handler mee moesten. De backlog-ID's (`H4:`, `R1:`, `R5:`, `R3:`, `O-…`) zijn uit de
commentaren gehaald — de reden blijft staan, het label zei een toekomstige lezer
niets.

**Frontend.** De dode e-mail-OTP-loginstroom is weg, net als `JwtPayload`,
`loginTotp` en `resendVerification`. `ConfirmDialog` is geëxtraheerd. `api.ts` lekt
geen `AxiosResponse` meer naar aanroepers. Het tweemaal inline gecaste
loginresultaat heet nu `LoginResult`, met daarin alleen de vlaggen die echt
voorkomen.

## Talen en frameworks — zijn het de juiste geweest?

**Elixir/Phoenix voor de control plane: ja, en het is de keuze die het meest
oplevert.** De werklast is precies waar de BEAM voor gebouwd is: honderden
langlopende verbindingen (agent-polls, console-WebSockets), toezicht op
stateful processen (de relay, elke consolesessie) en een reconciler-lus die
naast alles door draait. Het console-relay is daar het scherpste voorbeeld van —
een loopback-listener, een WebSocket en een SSH-client die door één supervisor bij
elkaar gehouden worden, met een timeout per sessie. In Go of Node is dat allemaal
te bouwen; hier was het een GenServer.

**Go voor de agent: ja, zonder voorbehoud.** Eén statisch binair bestand, geen
runtime om op iemands node te installeren, cross-compileert. Dat is de hele
eisenlijst voor een agent en Go vinkt hem af.

**Next.js voor de frontend: het zwaarste onderdeel van de stapel, en het levert
het minste op.** 20 van de 22 app-router-bestanden beginnen met `"use client"`, en
elke `async function` in die bestanden is een `useEffect`-fetcher tegen de JSON-API.
Er is geen server component die data haalt, geen server action, geen streaming.
Sinds de nonce-CSP staat elke route bovendien op `force-dynamic`, dus ook de
statische generatie — het laatste stuk Next dat nog meedeed — is uit.

Wat er overblijft is Next als router en bundler voor een SPA. Een Vite + React-SPA
zou hetzelfde doen met minder bewegende delen, en Phoenix LiveView zou de hele
API-laag overbodig maken.

**Toch geen aanbeveling om te migreren.** De app werkt, laadt in 80–95 ms door
Cloudflare, en heeft 1,9 MB aan statische chunks — niets daarvan is een probleem
dat een klant merkt. De prijs van Next is complexiteit die je pas voelt als je iets
ongewoons wilt, en dat gebeurt hier zelden. Dit is een observatie voor als er ooit
een reden is om de frontend aan te raken, geen werk dat op zichzelf de moeite waard
is.

## Deze ronde erbij

`ControlPlane.Clock` vervangt drie identieke `defp now/0`-helpers en zestien losse
`DateTime.utc_now() |> DateTime.truncate(:second)`. Truncatie is hier geen
stijlkeuze: elke `utc_datetime`-kolom bewaart hele seconden en Ecto weigert een
`DateTime` met microseconden in plaats van hem af te ronden, dus die regel werd op
negentien plekken opnieuw afgeleid. `Clock.shift/1` vervangt de vier
`DateTime.add(now(), -ttl, :second)`-vormen waarmee elke sweep zijn cutoff schrijft.

Het heet `Clock` en niet `Time` omdat `alias ControlPlane.Time` de `Time` van Elixir
zelf zou overschaduwen — een val voor wie hierna `Time.utc_now()` schrijft.

`esxi.isNotFound` doet zijn getypeerde controles nu met `errors.As` en loopt de
foutketen af voor de soap fault (govmomi's drager daarvan is unexported, dus
`errors.As` heeft er niets om op te richten). Eerlijk over wat dat oplost: de
string-fallback ving deze gevallen al — een mutatie naar de oude type-assertie laat
geen enkele test vallen. Het punt is dat het antwoord niet meer van govmomi's
formulering afhangt, en de nieuwe tests leggen het antwoord vast, niet de route
ernaartoe.

`error` is nu overal een machinecode. Dertien endpoints antwoordden met een Engelse
zin (`"invalid email or password"`, `"missing token"`) terwijl de rest snake_case
gebruikte; de zin staat nu in `detail`, waar hij thuishoort. Dat was niet alleen
inconsistent: de vertaaltabel van de frontend zocht op `invalid_credentials`, een
code die de control plane nooit stuurde, dus die vertaling sloeg altijd over naar de
generieke fallback. De tabel dekt nu de codes die een klant echt kan raken, per
gebied gegroepeerd.

Een test leest de codes uit de broncode en eist snake_case zonder hoofdletters of
leestekens, plus vier gevallen tegen de echte endpoints. Zonder zoiets valt een code
die terugzakt naar een zin niet op — hij breekt niets, hij stopt alleen stilletjes
met vertaald worden.

De Nederlandse teksten die overblijven staan in de server-gerenderde inlogformulieren,
waar het de zin is die iemand leest en geen code waar een client op schakelt. Dat is
goed zo; de review las dat als een probleem en dat was het niet.

## Nog open

### Control plane
- **[MED]** `@spec` op de publieke Fleet/Provisioning/Billing/Credits/Accounts-API.
- **[LOW]** De `attrs[:x] || attrs["x"]`-dans normaliseren op de grens van
  `create_vps/1` in plaats van overal.

### Agent
- **[AFGEWEZEN]** `withClient(ctx, fn)` voor de connect-en-defer-logout-boilerplate
  in esxi.go. Bij nader inzien geen verbetering: het gaat om vier idiomatische
  Go-regels die elke lezer in één oogopslag pakt, en om ze weg te halen moet het
  hele lichaam van zeven methodes een closure in — een extra inspringniveau, en
  `return` gaat er iets anders betekenen. De zeven aanroepers geven bovendien elk
  een andere nulwaarde terug (`rollbackClone` slikt de fout zelfs anders), dus het
  zou generics vragen om iets op te lossen dat geen probleem is.

### Frontend
- **[MED]** 17 pagina's schrijven hun eigen loading/error/try-catch. Een
  `useApiData(fetcher)`-hook haalt dat weg; dit is de grootste resterende
  onderhoudswinst aan die kant.
- **[LOW]** Commentaar staat door elkaar in Nederlands en Engels (`safeNext` is in
  allebei becommentarieerd).

### Wat bewust NIET gedaan is
- **Paginering op de beheertabellen.** De grootste tabel is `usage_records` met 205
  rijen; `users` heeft er zes. De lijst-endpoints hebben al een `limit` van 500/1000
  en de indexen die er bij groei toe doen staan er. Bouwen voor een schaal die er
  niet is kost onderhoud zonder afnemer.
- **`usage_records` partitioneren.** Zelfde reden. Bij 100 actieve VPSen is dat
  ~876k rijen per jaar; de `metered_at`-index draagt dat ruim. Terugkomen als het
  tienvoudige in zicht is.
