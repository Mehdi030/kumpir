// Offline-Simulation der Spielregeln (Formeln 1:1 aus den SQL-Funktionen)
const U = Math.random;
const speeds = { fast: [9, 16], normal: [14, 26], calm: [22, 40] };
function fuseSeconds(speed, alive, roundNo) {
  const [bmin, bmax] = speeds[speed];
  const sa = Math.max(0.75, Math.min(1.25, 1.15 - alive * 0.035));
  const sr = Math.max(0.45, 1 - Math.max(0, roundNo - 1) * 0.06);
  const sd = alive <= 2 ? 0.8 : 1;
  const mn = Math.max(3, bmin * sa * sr * sd);
  const mx = Math.max(mn + 1, bmax * sa * sr * sd);
  const raw = mn + Math.pow(U(), 1.9) * (mx - mn);
  return Math.max(3, Math.round(raw / 0.5) * 0.5);
}
const bonusBase = (r) => (r <= 2 ? 4 : r <= 4 ? 3 : r <= 6 ? 2 : 1);
const bonusCap = (n) => Math.max(12, Math.min(30, n * 3));
const surv = (r) => (r <= 1 ? 0.9 : r === 2 ? 0.6 : r === 3 ? 0.4 : r === 4 ? 0.2 : Math.max(0.1, 0.2 - (r - 4) * 0.05));
function survival(r, skill) {
  if (skill === 1) return Math.max(0.08, surv(r) * 0.7);
  if (skill === 3) return Math.max(0.5, 0.97 - (Math.max(r, 1) - 1) * 0.11);
  return surv(r);
}
const delayOf = (skill) => (skill === 1 ? 2.4 + U() * 3.0 : skill === 3 ? 0.8 + U() * 1.2 : 1.2 + U() * 2.6);
const artistChance = (skill) => (skill === 1 ? 0.45 : skill === 3 ? 0 : 0.15);

function simulateRound(skills, speed) {
  const n0 = skills.length;
  const alive = skills.map((_, i) => i);
  const out = []; // Ausscheide-Reihenfolge
  let roundNo = 1;
  let holderPos = Math.floor(U() * n0);
  let t = 0;
  let stats = { passes: 0, bonusGiven: 0, fuses: [], holdTimes: [] };
  let combo = Array(n0).fill(0);
  while (alive.length > 1) {
    const fuse = fuseSeconds(speed, alive.length, roundNo);
    stats.fuses.push(fuse);
    let tEnd = t + fuse;
    let used = 0;
    // Halte-Kette bis zur Explosion
    for (;;) {
      const h = alive[holderPos % alive.length];
      const skill = skills[h];
      const d = delayOf(skill);
      const willAnswer = U() < survival(roundNo, skill);
      if (!willAnswer || t + d >= tEnd) {
        // Explosion beim Halter
        t = tEnd;
        out.push(h);
        alive.splice(alive.indexOf(h), 1);
        combo[h] = 0;
        holderPos = alive.length ? alive.findIndex((x) => x > h) : 0;
        if (holderPos < 0) holderPos = 0;
        roundNo++;
        break;
      }
      // Antwort
      t += d;
      stats.holdTimes.push(d);
      stats.passes++;
      const title = U() >= artistChance(skill);
      const q = title ? 1 : 0.5;
      const diff = [0.8, 1, 1.3][Math.floor(U() * 3)];
      let comboBonus = 0;
      if (title) { combo[h]++; comboBonus = combo[h] >= 2 ? Math.min(2, 0.5 * (combo[h] - 1)) : 0; } else combo[h] = 0;
      let bonus = bonusBase(roundNo) * q * diff + comboBonus;
      if (alive.length <= 2) bonus = 0;
      const applied = Math.max(0, Math.min(bonus, bonusCap(alive.length) - used));
      used += applied; tEnd += applied; stats.bonusGiven += applied;
      holderPos = (holderPos + 1) % alive.length;
    }
  }
  const winner = alive[0];
  out.push(winner);
  return { order: out, winner, duration: t, passes: stats.passes, bonus: stats.bonusGiven, fuses: stats.fuses };
}

function run(label, skills, speed, N = 4000) {
  const wins = Array(skills.length).fill(0);
  const placeSum = Array(skills.length).fill(0);
  let dur = 0, passes = 0, bonus = 0, firstOut = Array(skills.length).fill(0);
  const durations = [];
  for (let i = 0; i < N; i++) {
    const r = simulateRound(skills, speed);
    wins[r.winner]++;
    r.order.forEach((p, idx) => { placeSum[p] += r.order.length - idx; });
    firstOut[r.order[0]]++;
    dur += r.duration; passes += r.passes; bonus += r.bonus; durations.push(r.duration);
  }
  durations.sort((a, b) => a - b);
  console.log(`\n=== ${label} | ${speed} | ${skills.length} Spieler (Seiten 0..${skills.length - 1}: Stufe ${skills.join(",")})`);
  console.log(`Rundendauer: Ø ${(dur / N).toFixed(0)} s, Median ${durations[N >> 1].toFixed(0)} s, 90 % ≤ ${durations[Math.floor(N * 0.9)].toFixed(0)} s | Pässe/Runde Ø ${(passes / N).toFixed(1)} | Bonuszeit/Runde Ø ${(bonus / N).toFixed(1)} s`);
  console.log("Siege je Sitz:      " + wins.map((w) => ((100 * w) / N).toFixed(1) + "%").join("  "));
  console.log("Ø Platz je Sitz:    " + placeSum.map((p) => (p / N).toFixed(2)).join("  ") + "  (Platz 1 = bester)");
  console.log("Zuerst raus je Sitz:" + firstOut.map((w) => ((100 * w) / N).toFixed(1) + "%").join("  "));
}

run("Gleich starke Mittel-Bots (Fairness der Sitzplätze)", [2, 2, 2, 2, 2, 2], "fast");
run("Gleich starke Profis", [3, 3, 3, 3, 3, 3], "fast");
run("Gemischt", [1, 2, 3, 1, 2, 3], "fast");
run("8 Spieler Profis", [3, 3, 3, 3, 3, 3, 3, 3], "fast");
run("Profis, normales Tempo", [3, 3, 3, 3, 3, 3], "normal");
run("Duell 2 Profis", [3, 3], "fast");
run("Duell Profi gegen Anfänger", [3, 1], "fast");
