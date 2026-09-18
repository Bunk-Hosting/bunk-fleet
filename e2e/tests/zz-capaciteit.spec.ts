import { test, expect, pwRequest } from "../lib/fixtures";
import { gezondheidsverslag, trageMomenten } from "../lib/fixtures";
import { APP } from "../lib/targets";

/**
 * Loopt als laatste (vandaar de zz-naam): wat heeft de suite zélf met de dienst
 * gedaan?
 *
 * Dit is geen functionele test maar een capaciteitsmeting. VM102 heeft 2 vCPU
 * en 4 GB en draait naast deze tests ook de control plane, de frontend,
 * Postgres en de edge. Als een browsersuite van één worker de dienst al
 * merkbaar vertraagt, is dat een bevinding over de machine — niet over de
 * tests.
 */

test("de dienst is de suite doorgekomen zonder weg te zakken", async () => {
  console.log(`[capaciteit] ${gezondheidsverslag()}`);

  // Tien metingen achter elkaar: hoe snel is /healthz nu, na alles?
  const ctx = await pwRequest.newContext();
  const metingen: number[] = [];
  for (let i = 0; i < 10; i++) {
    const t0 = Date.now();
    const res = await ctx.get(`${APP}/healthz`);
    metingen.push(Date.now() - t0);
    expect.soft(res.status(), "healthz na afloop").toBe(200);
  }
  await ctx.dispose();

  metingen.sort((a, b) => a - b);
  const mediaan = metingen[Math.floor(metingen.length / 2)];
  const hoogste = metingen[metingen.length - 1];
  console.log(`[capaciteit] healthz na afloop: mediaan ${mediaan} ms, hoogste ${hoogste} ms`);

  expect.soft(mediaan, `mediane healthz-latency ${mediaan} ms`).toBeLessThan(1000);
  expect
    .soft(
      trageMomenten,
      `de dienst zakte tijdens de run weg; dat is capaciteit, niet toeval: ${gezondheidsverslag()}`,
    )
    .toEqual([]);
});
