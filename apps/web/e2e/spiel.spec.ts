import { expect, test } from "@playwright/test";

// Langer Spiel-Test: echte Lobby gegen Bots (schreibt in die echte Datenbank, Lobbys werden nach kurzer Zeit automatisch geschlossen).
// Nur mit E2E_FLOW=1:  E2E_FLOW=1 npm run e2e
test.skip(!process.env.E2E_FLOW, "nur mit E2E_FLOW=1 (schreibt in die echte Datenbank)");

test("Solo gegen Bots im Roulette: Lobby startet, Roulette dreht", async ({ page }) => {
    await page.goto("/host?modus=bots");
    const name = page.getByLabel("Dein Name");
    if (await name.count()) await name.fill("Playwright");
    await page.getByText(/Roulette/).first().click();
    await page.getByRole("button", { name: /Gegen \d Bots? spielen/ }).first().click();
    await page.waitForURL(/\/game\/[A-Z0-9]{4}/, { timeout: 30_000 });
    // Das Roulette zeigt Buchstabe + Kategorien (oder die Dreh-Szene)
    await expect(page.getByText(/Buchstabe|Kategorie|Welche/i).first()).toBeVisible({ timeout: 30_000 });
});
