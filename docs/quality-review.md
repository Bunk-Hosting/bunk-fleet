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
