# 🗄️ KUMPIR — Datenbank-Verzeichnis

Hier liegt das **Datenbank-Schema** als Code (SQL).

> ✅ **Stand 2026-09-27 (Migration 020):** `schema.sql` (Tabellen) und
> `functions.sql` (alle RPCs) sind beide aktuell und manuell gepflegt.
> Nach jeder neuen `db/migrations/NNN_*.sql` bitte beide Dateien von
> Hand nachziehen, siehe Kommentar am Kopf jeder Datei.

---

## Struktur

```
db/
├── README.md          ← diese Datei
├── HOW_TO_DUMP.md      ← Anleitung um das echte Schema/Funktionen erneut zu dumpen
├── schema.sql          ← Tabellen-Referenz (Stand: siehe Kopf der Datei)
├── functions.sql       ← RPC-Funktionen-Referenz (Stand: siehe Kopf der Datei)
└── migrations/         ← alle Schema-Änderungen, chronologisch nummeriert
    └── README.md       ← vollständige, aktuell gehaltene Liste + Anwendungs-Anleitung
```

Für die aktuelle Liste aller Migrationen (was sie tun, ob Pflicht) siehe
[`migrations/README.md`](migrations/README.md) — nicht hier duplizieren,
sonst driftet es wieder auseinander wie zwischen 2026-05-11 und den
ersten Migrationen.

---

## 🔧 Dein echtes Schema neu dumpen

**Variante A — Supabase CLI (empfohlen, einmaliger Setup-Aufwand):**

```bash
# 1. Supabase CLI installieren (https://supabase.com/docs/guides/cli)
npm install -g supabase

# 2. Login in deinem Account
supabase login

# 3. Im Repo-Root: Projekt verknüpfen (Project-Ref findest du im Supabase-Dashboard URL)
supabase link --project-ref <DEIN_PROJECT_REF>

# 4. Schema dumpen (überschreibt die rekonstruierte Datei)
supabase db dump --schema public > db/schema.sql
supabase db dump --schema public --data-only > db/seed.sql   # optional
```

**Variante B — pg_dump direkt (wenn du Postgres-Connection-String hast):**

```bash
# Connection-String findest du im Supabase-Dashboard → Project Settings → Database
pg_dump "postgres://postgres:<PASSWORD>@db.<REF>.supabase.co:5432/postgres" \
  --schema-only --schema=public \
  > db/schema.sql
```

**Variante C — Supabase-Dashboard manuell:**

Dashboard → SQL Editor → führe aus:
```sql
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
ORDER BY proname;
```

Output vergleichst du gegen `db/functions.sql` und pflegst Abweichungen nach.

---

## 📝 Migrationen anwenden

Wenn eine neue Migration in `db/migrations/` liegt:

1. Datei öffnen, SQL prüfen
2. Im Supabase-Dashboard → SQL Editor einfügen → ausführen (oder komplett
   `db/migrations/_apply_all.sql` laufen lassen, idempotent)
3. **Oder** mit CLI: `supabase db push`

Migrationen sind **nummeriert + zeitstabil** — niemals umbenennen oder umordnen, sonst Chaos auf produktiven DBs.
