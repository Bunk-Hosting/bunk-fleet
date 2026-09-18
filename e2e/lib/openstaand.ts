import { test } from "@playwright/test";

/**
 * Markeert een test die vandaag faalt om een reden die bekend is en die niet in
 * deze repo gerepareerd kan worden.
 *
 * Waarom `test.fail()` en niet `test.skip()`: een overgeslagen test draait niet
 * en merkt dus nooit dat het probleem is opgelost. Een test die "hoort te
 * falen" draait wél, en zodra hij slaagt maakt Playwright de run rood met
 * "expected to fail but passed". Dan haalt iemand deze regel weg. Zo blijft de
 * suite groen zolang het punt openstaat, en precies één keer rood op het moment
 * dat het opgelost is -- in plaats van elke dag rood, wat hetzelfde is als geen
 * suite.
 *
 * `reden` hoort te zeggen wat er moet gebeuren en waar dat thuishoort, niet dat
 * het "nog niet af" is.
 *
 * Op dit moment gebruikt niemand hem: de vijf punten die er stonden -- de
 * securityheaders, de contrastfouten, de security.txt en de te kleine
 * menulinks op de marketingsite -- zijn opgelost. Hij blijft staan omdat dat
 * precies het patroon is dat je wilt op het moment dat er wéér iets buiten deze
 * repo kapot is, en omdat de uitleg erboven dan niet opnieuw bedacht hoeft te
 * worden.
 */
export function openstaand(reden: string): void {
  test.fail(true, `Openstaand: ${reden}`);
}

/**
 * Slaat een test over die alleen in een echte browser iets kan betekenen.
 *
 * Cloudflare Turnstile bedient een headless Chromium niet: er verschijnt geen
 * widget, dus er komt geen token, dus blijft de verzendknop uit en is hij ook
 * niet focusbaar. Dat is hoogstwaarschijnlijk het product dat doet wat het
 * moet doen -- een robot weren -- en niet een fout in ons formulier. Zolang
 * niemand dat met een gewone browser heeft bevestigd, is er over de widget
 * zelf niets te beweren vanaf hier.
 *
 * Wat hier NIET onder valt en dus gewoon draait: of de sleutel geconfigureerd
 * is. Dat is een eigenschap van onze pagina en die is headless prima te zien.
 */
export function alleenEchteBrowser(wat: string): void {
  test.skip(
    !process.env.BUNK_ECHTE_BROWSER,
    `${wat} is vanuit een headless browser niet vast te stellen; draai met BUNK_ECHTE_BROWSER=1 in een gewone browser`,
  );
}
