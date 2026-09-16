// ESLint 9 wil een flat config; het oude .eslintrc.json wordt niet meer gelezen.
// eslint-config-next levert die vorm sinds versie 15 zelf, dus dit is het hele
// bestand: dezelfde regelset als voorheen ("next/core-web-vitals"), nu als array.
import nextCoreWebVitals from "eslint-config-next/core-web-vitals";

const config = [
  {
    // Build- en afhankelijkheidsmappen horen niet in de lint. Onder de oude
    // config deed next lint dat impliciet; in een flat config staat het hier.
    ignores: ["node_modules/**", ".next/**", "out/**", "next-env.d.ts"],
  },
  ...(Array.isArray(nextCoreWebVitals) ? nextCoreWebVitals : [nextCoreWebVitals]),
];

export default config;
