# 📤 So gibst du Claude deine echte DB-Info

Du brauchst **kein CLI**. Drei Queries im Supabase-Dashboard reichen.

> 🔐 **Sicherheit:** Diese Queries lesen nur Schema-Infos (Tabellen, Funktionen, Policies). Sie geben **keine** Spielerdaten / Passwörter / Keys aus. Es ist sicher, den Output bei mir zu pasten oder zu committen.

---

## Schritt 1 — Schema (Tabellen + Spalten)

Im Supabase **SQL Editor** ausführen:

```sql
WITH cols AS (
  SELECT
    c.table_name,
    string_agg(
      '    ' || c.column_name || ' ' || c.data_type ||
      CASE WHEN c.is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END ||
      CASE WHEN c.column_default IS NOT NULL THEN ' DEFAULT ' || c.column_default ELSE '' END,
      E',\n' ORDER BY c.ordinal_position
    ) AS cols_text
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
  GROUP BY c.table_name
)
SELECT
  'CREATE TABLE ' || table_name || E' (\n' || cols_text || E'\n);' AS ddl
FROM cols
ORDER BY table_name;
```

Output → speichern als `db/schema.sql` (Inhalt ersetzt die `schema.reconstructed.sql`).

---

## Schritt 2 — RPC-Funktionen (alle 21+ Stück)

```sql
SELECT
  pg_get_functiondef(p.oid) || E';\n\n' AS function_def
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
ORDER BY p.proname;
```

Output → speichern als `db/functions.sql`.

---

## Schritt 3 — RLS Policies

```sql
SELECT
  'ALTER TABLE ' || schemaname || '.' || tablename || ' ENABLE ROW LEVEL SECURITY;' || E'\n' ||
  'CREATE POLICY "' || policyname || '" ON ' || schemaname || '.' || tablename ||
  ' FOR ' || cmd ||
  CASE WHEN roles::text <> '{public}' THEN ' TO ' || array_to_string(roles, ', ') ELSE '' END ||
  CASE WHEN qual IS NOT NULL THEN E'\n    USING (' || qual || ')' ELSE '' END ||
  CASE WHEN with_check IS NOT NULL THEN E'\n    WITH CHECK (' || with_check || ')' ELSE '' END ||
  ';' || E'\n' AS policy_ddl
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
```

Output → speichern als `db/policies.sql`.

---

## Wie du den Output abspeicherst

**Variante A (einfacher) — direkt zu Claude im Chat:**
Kopiere den Output aus dem SQL-Editor und füge ihn in den Chat ein, mit Vorspann:
> „Hier mein Schema: …"
> „Hier meine Funktionen: …"
> „Hier meine Policies: …"

**Variante B (besser für die Zukunft) — Datei im Repo:**
1. Öffne `apps/web` lokal in WebStorm
2. Erstelle `db/schema.sql` und füge Output rein
3. Gleich für `db/functions.sql` und `db/policies.sql`
4. Committe (`git add db/ && git commit -m "chore(db): echtes Schema dumpen"`)
5. Beim nächsten Mal sehe ich die Files automatisch

---

## Was Claude **NICHT** braucht (und du auch nicht teilen sollst)

- ❌ Service-Role-Key (`SUPABASE_SERVICE_ROLE_KEY`)
- ❌ Datenbank-Passwort
- ❌ Connection-String
- ❌ Echte User-Daten / Mail-Adressen

Falls du irgendwo so etwas in deinen `.env`-Dateien siehst — **nicht** in den Chat oder ins Repo packen!
