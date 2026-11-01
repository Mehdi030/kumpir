import { expect, test } from "@playwright/test";

// Diese Tests brauchen keine Anmeldung und laufen auch im Gast-Modus der CI (ohne echte Datenbank).

test("Startseite: Titel, Spielen-Knopf, Beitreten", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/Kumpir/);
    await expect(page.getByRole("link", { name: /Jetzt spielen/ }).or(page.getByRole("button", { name: /Jetzt spielen/ }))).toBeVisible();
    await expect(page.getByText("Mit Code beitreten").first()).toBeVisible();
});

test("Hosten: Modus-Auswahl und Startknopf sind da", async ({ page }) => {
    await page.goto("/host?modus=bots");
    await expect(page.getByText(/Buzzer/).first()).toBeVisible();
    await expect(page.getByText(/Roulette/).first()).toBeVisible();
});

test("Herausforderung: unbekannter Code zeigt eine freundliche Meldung", async ({ page }) => {
    await page.goto("/challenge/ZZZZZZ");
    await expect(page.getByText(/gibt es nicht/)).toBeVisible({ timeout: 15_000 });
});

test("Bestenliste: Seite lädt", async ({ page }) => {
    await page.goto("/leaderboard");
    await expect(page.getByRole("heading", { name: /Bestenliste/ })).toBeVisible();
});

test("Unbekannte Seite: eigene 404-Seite statt Absturz", async ({ page }) => {
    const res = await page.goto("/diese-seite-gibt-es-nicht");
    expect(res?.status()).toBe(404);
});

test("Keine unbehandelten Browser-Fehler auf der Startseite", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto("/");
    await page.waitForTimeout(3000);
    expect(errors).toEqual([]);
});
