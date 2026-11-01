import { defineConfig } from "@playwright/test";

/**
 * Browser-Tests der Hauptwege (Startseite, Hosten, Herausforderung, Bestenliste).
 * Sie nehmen den schon installierten Browser (kein Download): in CI Chrome, lokal z. B. E2E_CHANNEL=msedge.
 * Aufruf: npm run e2e   (startet bei Bedarf selbst den Entwicklungsserver auf Port 3000)
 * Der lange Spiel-Test (echte Lobby gegen Bots) läuft nur mit E2E_FLOW=1, weil er in die echte Datenbank schreibt.
 */
export default defineConfig({
    testDir: "./e2e",
    timeout: 60_000,
    retries: process.env.CI ? 1 : 0,
    reporter: [["list"]],
    use: {
        baseURL: process.env.E2E_BASE_URL ?? "http://localhost:3000",
        channel: process.env.E2E_CHANNEL ?? "chrome",
        trace: "retain-on-failure",
        locale: "de-DE",
    },
    webServer: process.env.E2E_BASE_URL
        ? undefined
        : {
              command: process.env.CI ? "npm run start" : "npm run dev",
              url: "http://localhost:3000",
              reuseExistingServer: true,
              timeout: 120_000,
          },
});
