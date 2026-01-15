🌿 BRANCH-WORKFLOW (BITTE EINHALTEN)

Dieses Projekt nutzt drei feste Branches, damit Web und Logic sauber getrennt bleiben
und niemand aus Versehen etwas überschreibt.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🏁 main
- gemeinsamer, stabiler Stand
- NIEMALS direkt hier arbeiten
- hier landet nur fertige Arbeit aus web oder logic

🌐 web (Medo)
- Arbeitsbereich: apps/web
- Medo arbeitet ausschließlich hier

🧠 logic (Sero)
- Arbeitsbereich: apps/logic
- Sero arbeitet ausschließlich hier

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔄 VOR DEM ARBEITEN (IMMER, FÜR ALLE)

git checkout main
git pull

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🌐 MEDO – WEB ARBEITEN

git checkout web
git merge main

(arbeiten, dann sichern)

git add .
git commit -m "feat(host): lobby erstellen"
git push

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🧠 SERO – LOGIC ARBEITEN

git checkout logic
git merge main

(arbeiten, dann sichern)

git add .
git commit -m "core(game): rundenlogik hinzufügen"
git push

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ WENN EIN SCHRITT FERTIG IST (IN main ÜBERNEHMEN)

MEDO:
git checkout main
git merge web
git push
git checkout web
git merge main

SERO:
git checkout main
git merge logic
git push
git checkout logic
git merge main

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📌 MERKSATZ

Jeder arbeitet nur in seinem Branch.
main ist die gemeinsame Wahrheit.
