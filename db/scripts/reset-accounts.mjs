// Löscht ALLE Konten (auth.users + alles, was daran hängt) – nach einer Sicherung in db/backups/.
//   node db/scripts/reset-accounts.mjs --yes
// Danach: neu registrieren und mit  node db/scripts/restore-admin.mjs <benutzername>  wieder zum Admin machen.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import pg from "pg";
if (!process.argv.includes("--yes")) { console.log("Nur mit --yes (löscht alle Konten unwiderruflich)."); process.exit(1); }
const env = Object.fromEntries(readFileSync("db/.env.local", "utf8").split(/\r?\n/).filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()]));
const db = new pg.Client({ host: env.SUPABASE_DB_HOST, port: 5432, database: "postgres", user: "postgres", password: env.SUPABASE_DB_PASSWORD, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = async (s, a) => (await db.query(s, a)).rows;
const backup = {
    at: new Date().toISOString(),
    users: await q("select id, email, created_at, last_sign_in_at, email_confirmed_at, raw_user_meta_data from auth.users order by created_at"),
    profiles: await q("select * from profiles"),
    account_matches: await q("select * from account_matches"),
    account_rounds: await q("select * from account_rounds"),
    season_points: await q("select * from season_points"),
    player_lifetime_stats: await q("select * from player_lifetime_stats"),
    player_achievements: await q("select * from player_achievements"),
    friendships: await q("select * from friendships"),
    staff_roles: await q("select * from staff_roles"),
};
mkdirSync("db/backups", { recursive: true });
const file = `db/backups/accounts-${backup.at.replace(/[:.]/g, "-")}.json`;
writeFileSync(file, JSON.stringify(backup, null, 1));
console.log(`💾 Sicherung: ${file} (${backup.users.length} Konten)`);

try {
    await db.query("begin");
    await db.query("alter table public.profiles disable trigger profiles_protect_last_admin");
    await db.query("delete from public.season_points");
    await db.query("delete from public.staff_roles");
    await db.query("delete from auth.users");
    await db.query("alter table public.profiles enable trigger profiles_protect_last_admin");
    await db.query("commit");
} catch (e) {
    await db.query("rollback").catch(() => {});
    console.error("❌ Abgebrochen, nichts gelöscht:", e.message);
    process.exit(1);
}
const [c] = await q("select (select count(*) from auth.users) users, (select count(*) from profiles) profiles, (select count(*) from account_matches) matches, (select count(*) from season_points) season, (select tgenabled from pg_trigger where tgname='profiles_protect_last_admin') trg");
console.log("Danach:", c);
await db.end();
