// Balance-Simulation mit "Mensch"-Modell + Punktesystem
const U = Math.random;
const speeds = { fast: [9, 16], normal: [14, 26], calm: [22, 40] };
function fuseSeconds(speed, alive, roundNo) {
  const [bmin, bmax] = speeds[speed];
  const sa = Math.max(0.75, Math.min(1.25, 1.15 - alive * 0.035));
  const sr = Math.max(0.45, 1 - Math.max(0, roundNo - 1) * 0.06);
  const sd = alive <= 2 ? 0.8 : 1;
  const mn = Math.max(3, bmin * sa * sr * sd);
  const mx = Math.max(mn + 1, bmax * sa * sr * sd);
  return Math.max(3, Math.round((mn + Math.pow(U(), 1.9) * (mx - mn)) / 0.5) * 0.5);
}
const bonusBase = (r) => (r <= 2 ? 4 : r <= 4 ? 3 : r <= 6 ? 2 : 1);
const bonusCap = (n) => Math.max(12, Math.min(30, n * 3));
const gauss = () => Math.sqrt(-2 * Math.log(U() || 1e-9)) * Math.cos(2 * Math.PI * U());
// Spielertypen: know = Wahrscheinlichkeit, den Song (Titel/Interpret) zu kennen; med = typische Reaktionszeit (s)
const TYPES = {
  gut: { know: 0.88, med: 3.2, sig: 0.4, artist: 0.1 },
  normal: { know: 0.72, med: 4.5, sig: 0.45, artist: 0.2 },
  schwach: { know: 0.5, med: 6.0, sig: 0.5, artist: 0.3 },
};
function holdOutcome(t, tEnd, type) {
  // Wrong guesses: kennt er den Song nicht, bleibt die Zeit bis zur Explosion
  const T = TYPES[type];
  if (U() > T.know) return { ok: false };
  let d = Math.exp(Math.log(T.med) + T.sig * gauss());
  d = Math.max(1.2, Math.min(d, 20));
  if (t + d >= tEnd) return { ok: false, late: true };
  return { ok: true, d, title: U() >= T.artist };
}
function simulateRound(types, speed) {
  const n0 = types.length;
  const alive = types.map((_, i) => i);
  const order = [];
  const sp = Array(n0).fill(0), clutch = Array(n0).fill(0), passes = Array(n0).fill(0);
  const combo = Array(n0).fill(0);
  let roundNo = 1, holderPos = Math.floor(U() * n0), t = 0;
  const fuseLog = [];
  let duelFuse = null, duelEnd = null;
  while (alive.length > 1) {
    const fuse = fuseSeconds(speed, alive.length, roundNo);
    if (alive.length === 2) duelFuse = fuse;
    fuseLog.push(fuse);
    let tEnd = t + fuse, used = 0;
    for (;;) {
      const h = alive[holderPos % alive.length];
      const o = holdOutcome(t, tEnd, types[h]);
      if (!o.ok) {
        t = tEnd; order.push(h); alive.splice(alive.indexOf(h), 1); combo[h] = 0;
        holderPos = alive.length ? alive.findIndex((x) => x > h) : 0; if (holderPos < 0) holderPos = 0;
        roundNo++; break;
      }
      t += o.d; passes[h]++;
      if (tEnd - t <= 2) clutch[h]++;
      sp[h] += o.title ? 1 : 0.5;
      let cb = 0;
      if (o.title) { combo[h]++; cb = combo[h] >= 2 ? Math.min(2, 0.5 * (combo[h] - 1)) : 0; } else combo[h] = 0;
      let bonus = bonusBase(roundNo) * (o.title ? 1 : 0.5) * [0.8, 1, 1.3][Math.floor(U() * 3)] + cb;
      if (alive.length <= 2) bonus = 0;
      const ap = Math.max(0, Math.min(bonus, bonusCap(alive.length) - used)); used += ap; tEnd += ap;
      holderPos = (holderPos + 1) % alive.length;
    }
  }
  order.push(alive[0]);
  return { order, duration: t, fuseLog, duelFuse, sp, clutch, passes };
}

function stats(label, types, speed, N = 3000) {
  let dur = 0, firstFuseSum = 0, firstDies = 0, duelFuseSum = 0, duelCount = 0, passTot = 0, spTot = 0;
  let placementPts = 0, songPts = 0, clutchPts = 0;
  const n = types.length;
  for (let i = 0; i < N; i++) {
    const r = simulateRound(types, speed);
    dur += r.duration; firstFuseSum += r.fuseLog[0];
    if (r.duelFuse != null) { duelFuseSum += r.duelFuse; duelCount++; }
    passTot += r.passes.reduce((a, b) => a + b, 0);
    r.order.forEach((p, idx) => { const place = n - idx; placementPts += n > 1 ? (100 * (n - place)) / (n - 1) : 100; });
    songPts += r.sp.reduce((a, b) => a + b, 0) * 15;
    clutchPts += r.clutch.reduce((a, b) => a + b, 0) * 10;
  }
  const tot = placementPts + songPts + clutchPts;
  console.log(`${label.padEnd(44)} | ${speed.padEnd(6)} | Dauer Ø ${(dur / N).toFixed(0).padStart(3)} s | Pässe/Spieler Ø ${(passTot / N / n).toFixed(1).padStart(4)} | Duell-Zündschnur Ø ${(duelFuseSum / Math.max(1, duelCount)).toFixed(1)} s | Punkte: Platz ${((100 * placementPts) / tot).toFixed(0)} % / Songs ${((100 * songPts) / tot).toFixed(0)} % / Clutch ${((100 * clutchPts) / tot).toFixed(0)} %`);
}

// Fairness der Wertung: gewinnt der Spieler mit der besten Platzierung auch nach Punkten?
function series(label, types, speed, rounds = 5, N = 1500) {
  const n = types.length;
  let sameWinner = 0, bestTypeWins = 0, bestWinsByPlacement = 0, earlyHighScorer = 0;
  const winsByType = {};
  for (let k = 0; k < N; k++) {
    const pts = Array(n).fill(0), plc = Array(n).fill(0);
    for (let r = 0; r < rounds; r++) {
      const x = simulateRound(types, speed);
      x.order.forEach((p, idx) => {
        const place = n - idx;
        plc[p] += place; // kleiner = besser
        pts[p] += Math.round((100 * (n - place)) / (n - 1)) + Math.round(x.sp[p] * 15) + x.clutch[p] * 10;
      });
    }
    const wPts = pts.indexOf(Math.max(...pts));
    const wPlc = plc.indexOf(Math.min(...plc));
    if (wPts === wPlc) sameWinner++;
    winsByType[types[wPts]] = (winsByType[types[wPts]] || 0) + 1;
  }
  console.log(`${label.padEnd(44)} | Match-Sieger nach Punkten = Sieger nach Platzierung: ${((100 * sameWinner) / N).toFixed(0)} % | Siege nach Typ: ` + Object.entries(winsByType).map(([t, w]) => `${t} ${((100 * w) / N).toFixed(0)}%`).join(", "));
}

console.log("=== Rundenverlauf mit menschlichen Spielern (normal = kennt 72 % der Songs, ~4,5 s Reaktion) ===");
for (const sp of ["fast", "normal", "calm"]) {
  for (const n of [3, 4, 6, 8, 12]) stats(`${n} normale Spieler`, Array(n).fill("normal"), sp, 1500);
  console.log("");
}
console.log("=== Wertung (5-Runden-Match) ===");
series("6 Spieler: 2 gut, 2 normal, 2 schwach", ["gut", "gut", "normal", "normal", "schwach", "schwach"], "fast");
series("4 Spieler: 1 gut, 3 normal", ["gut", "normal", "normal", "normal"], "fast");
series("6 Spieler alle normal", Array(6).fill("normal"), "fast");

console.log("\n=== Überlebenschance eines Halters (Mensch 'normal' kennt 72 %): Duell und erste Halte-Phase ===");
function pSurvive(speed, alive, roundNo, type, N = 20000) {
  let ok = 0, fuseSum = 0;
  for (let i = 0; i < N; i++) { const f = fuseSeconds(speed, alive, roundNo); fuseSum += f; if (holdOutcome(0, f, type).ok) ok++; }
  return `${((100 * ok) / N).toFixed(0)} % (Ø Schnur ${(fuseSum / N).toFixed(1)} s)`;
}
for (const sp of ["fast", "normal", "calm"]) {
  console.log(`-- ${sp}`);
  for (const n of [3, 4, 6, 8, 12]) {
    console.log(`   ${String(n).padStart(2)} Spieler: erste Schnur (2 Pässe-Bonus noch nicht): ${pSurvive(sp, n, 1, "normal")} | Duell am Ende (2 Lebende, Zug ${n - 1}): ${pSurvive(sp, 2, n - 1, "normal")} | gut: ${pSurvive(sp, 2, n - 1, "gut")}`);
  }
}
