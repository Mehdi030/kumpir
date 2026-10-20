/** Breite eines Buchstabens auf der Walze (px) – wird auch in der Walzen-Rechnung gebraucht */
export const ITEM = 104;

/**
 * Aussehen des Roulettes – gleiche Bühne wie Buzzer-Arena und Zeitreise: dunkler Hintergrund, Kopfzeile mit Modus/Ziel/Zähler,
 * Zeitleiste, eine Szene in der Mitte und unten die Pulte der Spieler (Figuren auf Blöcken, die mit den Punkten wachsen).
 */
export const STYLES = `
.lrMain{ min-height: 100dvh; color: #fff; display: flex; flex-direction: column; gap: 6px; padding: 12px 14px 0; position: relative; overflow-x: hidden;
  background: radial-gradient(ellipse 55% 45% at 50% -5%, rgba(255,214,120,.22), transparent 70%), radial-gradient(ellipse 40% 60% at 12% 30%, rgba(255,70,140,.10), transparent 70%),
              radial-gradient(ellipse 40% 60% at 88% 30%, rgba(90,120,255,.12), transparent 70%), linear-gradient(180deg, #1f1033 0%, #120a22 55%, #0a0614 100%); }
.lrTopRight{ position: fixed; top: 14px; right: 14px; z-index: 60; }
.lrHead{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 0 64px 0 128px; min-height: 40px; }
@media (max-width: 640px){ .lrHead{ padding-left: 52px; } }
.lrMode{ font-family: var(--font-display); font-weight: 900; font-size: clamp(20px, 3vw, 28px); }
.lrGoal{ padding: 6px 12px; border-radius: 999px; font-weight: 900; font-size: 13.5px; background: rgba(255,210,63,.16); border: 1px solid rgba(255,210,63,.5); color: #ffe08a; }
.lrCount{ margin-left: auto; padding: 6px 12px; border-radius: 999px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.16); font-weight: 850; font-size: 13px; }
.lrBar{ height: 6px; border-radius: 999px; background: rgba(255,255,255,.1); overflow: hidden; }
.lrBarFill{ height: 100%; transform-origin: left center; transition: transform .25s linear; background: linear-gradient(90deg, #ffd23f, #ff9d2e); }
.lrBarFill.hot{ background: linear-gradient(90deg, #ff6a3c, #ff2e4a); }

/* Szene in der Mitte */
.lrScene{ flex: 1; display: flex; flex-direction: column; align-items: center; gap: 12px; width: min(980px, 100%); margin: 0 auto; padding: 6px 0 10px; min-width: 0; animation: lrIn .4s cubic-bezier(.16,1,.3,1); }
@keyframes lrIn{ from{ opacity: 0; transform: translateY(12px); } }
.lrScene > *{ min-width: 0; max-width: 100%; }
.lrKick{ font-size: 12px; font-weight: 900; letter-spacing: 2px; text-transform: uppercase; opacity: .75; text-align: center; }

/* Kopf-Karte der Szene: Buchstabe, Text, Zeit-Ring */
.lrPanel{ width: 100%; display: flex; align-items: center; gap: 16px; padding: 12px 18px; border-radius: 24px; background: linear-gradient(160deg, rgba(255,255,255,.13), rgba(255,255,255,.05)); border: 1px solid rgba(255,255,255,.2); box-shadow: 0 14px 34px rgba(0,0,0,.3); }
.lrLetter{ flex: none; width: 84px; height: 84px; border-radius: 24px; display: grid; place-items: center; font-family: var(--font-display); font-weight: 900; font-size: 58px; color: #2a1200; line-height: 1;
  background: linear-gradient(160deg, #fff0a8, #ffc22e 60%, #ff9d2e); box-shadow: 0 6px 0 #a85a08, 0 14px 30px rgba(255,170,30,.4); }
.lrPanelText{ display: grid; gap: 2px; min-width: 0; flex: 1; }
.lrPanelText small{ font-size: 11px; font-weight: 900; letter-spacing: 1.5px; text-transform: uppercase; opacity: .7; }
.lrPanelText h1, .lrPanelText h2{ margin: 0; font-family: var(--font-display); font-weight: 900; font-size: clamp(24px, 4vw, 38px); line-height: 1.05; overflow-wrap: anywhere; }
.lrPanelText span{ font-size: 13px; font-weight: 700; opacity: .82; }
.lrRing{ position: relative; flex: none; width: 64px; height: 64px; }
.lrRing svg{ position: absolute; inset: 0; width: 100%; height: 100%; }
.lrRingBg{ fill: none; stroke: rgba(255,255,255,.14); stroke-width: 6; }
.lrRingFg{ fill: none; stroke: #ffd23f; stroke-width: 6; stroke-linecap: round; transition: stroke-dashoffset .25s linear, stroke .3s ease; }
.lrRing.hot .lrRingFg{ stroke: #ff5a4a; }
.lrRingNum{ position: absolute; inset: 0; display: grid; place-items: center; font-family: var(--font-display); font-weight: 900; font-size: 24px; color: #ffe08a; }
.lrRing.hot .lrRingNum{ color: #ff9d94; animation: lrBeat .7s ease-in-out infinite alternate; }
@keyframes lrBeat{ from{ transform: scale(1); } to{ transform: scale(1.14); } }

/* Spielautomat mit Walze */
.lrCab{ position: relative; width: min(900px, 100%); padding: 12px 14px 10px; border-radius: 30px;
  background: linear-gradient(180deg, #5a3a1c 0%, #2c1a0c 100%); border: 2px solid rgba(255,214,120,.7);
  box-shadow: 0 0 0 5px rgba(255,210,63,.12), 0 24px 60px rgba(0,0,0,.55), inset 0 2px 0 rgba(255,255,255,.25), inset 0 -4px 14px rgba(0,0,0,.5); }
.lrLamps{ display: flex; justify-content: space-between; padding: 0 8px; }
.lrLamps.top{ margin-bottom: 8px; } .lrLamps.bottom{ margin-top: 8px; }
.lrLamps i{ width: 10px; height: 10px; border-radius: 50%; background: #ffd23f; box-shadow: 0 0 10px rgba(255,210,63,.9); animation: lrLamp .9s steps(1) infinite; animation-delay: calc(var(--k) * .09s); }
@keyframes lrLamp{ 0%{ opacity: 1; } 50%{ opacity: .25; box-shadow: none; } }
.lrCab.landed .lrLamps i{ animation: lrLampWin .5s ease-in-out 4 alternate; animation-delay: 0s; opacity: 1; }
@keyframes lrLampWin{ from{ filter: brightness(1); } to{ filter: brightness(1.8); transform: scale(1.35); } }
.lrReelWrap{ position: relative; width: 100%; height: 160px; overflow: hidden; border-radius: 18px; background: linear-gradient(180deg, #fffdf2 0%, #f1e6c6 50%, #fffdf2 100%); border: 3px solid #1a0f06;
  box-shadow: inset 0 10px 22px rgba(0,0,0,.45), inset 0 -10px 22px rgba(0,0,0,.45); }
.lrReelWrap::before, .lrReelWrap::after{ content: ""; position: absolute; top: 0; bottom: 0; width: 24%; z-index: 2; pointer-events: none; }
.lrReelWrap::before{ left: 0; background: linear-gradient(90deg, rgba(40,22,8,.85), transparent); }
.lrReelWrap::after{ right: 0; background: linear-gradient(270deg, rgba(40,22,8,.85), transparent); }
.lrReel{ position: absolute; left: 50%; top: 0; height: 100%; display: flex; align-items: center; will-change: transform; }
.lrCell{ flex: none; width: ${ITEM}px; text-align: center; font-family: var(--font-display); font-weight: 900; font-size: 92px; line-height: 1; color: #3b2410; opacity: .75; }
.lrCell.hit{ color: #c2380d; opacity: 1; text-shadow: 0 0 26px rgba(255,120,40,.7); animation: lrHit .5s cubic-bezier(.3,1.6,.5,1) both; }
@keyframes lrHit{ from{ transform: scale(.8); } to{ transform: scale(1.16); } }
.lrWin{ position: absolute; left: 50%; top: 6px; bottom: 6px; width: ${ITEM + 10}px; transform: translateX(-50%); border: 3px solid #e0261b; border-radius: 14px; z-index: 3; pointer-events: none; box-shadow: 0 0 18px rgba(224,38,27,.5); }
.lrPointer, .lrPointerB{ position: absolute; left: 50%; transform: translateX(-50%); z-index: 4; color: #e0261b; font-size: 18px; text-shadow: 0 1px 2px rgba(0,0,0,.5); line-height: 1; }
.lrPointer{ top: 0; } .lrPointerB{ bottom: 0; }

/* Abstimmung */
.lrVotes{ width: 100%; display: grid; gap: 8px; margin-top: auto; }
.lrVotes.rise{ animation: lrRise .8s cubic-bezier(.16,1,.3,1) .5s both; }
@keyframes lrRise{ from{ opacity: 0; transform: translateY(60px); } }
.lrVoteHint{ display: flex; align-items: center; justify-content: space-between; gap: 10px; font-size: 13px; font-weight: 800; opacity: .92; }
.lrVoteHint b{ color: #ffe08a; font-family: var(--font-display); font-size: 17px; }
.lrVoteGrid{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.lrVoteCard{ --h: 40; position: relative; display: grid; justify-items: center; align-content: center; gap: 6px; padding: 16px 10px 12px; min-height: 150px; border-radius: 24px; cursor: pointer; color: #fff; font: inherit; overflow: hidden;
  background: linear-gradient(165deg, hsla(var(--h), 85%, 62%, .34), hsla(var(--h), 70%, 35%, .16) 70%); border: 2px solid hsla(var(--h), 90%, 75%, .45);
  box-shadow: 0 12px 26px rgba(0,0,0,.28); transition: transform .18s ease, border-color .18s ease, box-shadow .18s ease; }
.lrVoteCard:hover:not(:disabled){ transform: translateY(-5px); border-color: hsla(var(--h), 95%, 82%, .9); }
.lrVoteCard.on{ border-color: #ffd23f; box-shadow: 0 0 0 4px rgba(255,210,63,.25), 0 16px 34px rgba(0,0,0,.4), 0 0 30px hsla(var(--h), 90%, 60%, .45); transform: translateY(-3px); }
.lrVoteCard:disabled{ cursor: default; opacity: .88; }
.lrVoteNo{ position: absolute; top: 8px; left: 10px; width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 13px; background: rgba(0,0,0,.35); }
.lrVoteCard.on .lrVoteNo{ background: #ffd23f; color: #2a1200; }
.lrVoteCheck{ position: absolute; top: 8px; right: 10px; font-weight: 900; color: #ffd23f; animation: lrPop .3s cubic-bezier(.2,1.6,.4,1); }
.lrVoteIcon{ width: 62px; height: 62px; border-radius: 50%; display: grid; place-items: center; font-size: 34px; line-height: 1; background: rgba(0,0,0,.28); box-shadow: inset 0 0 0 2px hsla(var(--h), 90%, 80%, .35); }
.lrVoteName{ font-family: var(--font-display); font-size: clamp(18px, 2.4vw, 26px); line-height: 1.1; text-align: center; overflow-wrap: anywhere; }
.lrVoteDots{ display: flex; gap: 5px; flex-wrap: wrap; justify-content: center; min-height: 14px; }
.lrVoteDots i{ width: 14px; height: 14px; border-radius: 50%; background: #ffd23f; box-shadow: 0 0 8px rgba(255,210,63,.7); animation: lrPop .35s cubic-bezier(.2,1.6,.4,1); }
.lrVoteDots em{ font-style: normal; opacity: .4; }
@keyframes lrPop{ from{ opacity: 0; transform: translateY(-10px) scale(.85); } }

/* Eingabe */
.lrForm{ display: flex; gap: 8px; width: 100%; }
.lrInput{ flex: 1; min-width: 0; height: 54px; border-radius: 16px; border: 2px solid #ffd23f; background: rgba(0,0,0,.38); color: #fff; font: inherit; font-size: 19px; font-weight: 800; padding: 0 16px; outline: none; box-shadow: 0 0 0 4px rgba(255,210,63,.18); }
.lrInput:focus{ box-shadow: 0 0 0 5px rgba(255,210,63,.32); }
.lrInput::placeholder{ color: rgba(255,255,255,.45); font-weight: 600; }
.lrInput:disabled{ opacity: .6; box-shadow: none; border-color: rgba(255,255,255,.25); }
.lrAdd{ flex: none; height: 54px; }
.lrCountRow{ width: 100%; display: flex; align-items: center; gap: 8px; font-weight: 800; }
.lrCountRow b{ font-family: var(--font-display); font-size: 26px; color: #ffe08a; }
.lrDone{ margin-left: auto; }
.lrWatch{ text-align: center; font-weight: 800; opacity: .8; padding: 14px 0; }

/* Wörter-Karte */
.lrMap{ --rh: 52px; position: relative; width: 100%; border-radius: 24px; background: radial-gradient(ellipse at 50% 35%, rgba(255,255,255,.12), rgba(255,255,255,.03) 70%); border: 1px solid rgba(255,255,255,.2); box-shadow: inset 0 0 40px rgba(0,0,0,.25), 0 14px 34px rgba(0,0,0,.28); overflow: hidden; }
.lrBoardTag{ position: absolute; left: 14px; top: 10px; z-index: 6; padding: 3px 10px; border-radius: 999px; font-size: 11px; font-weight: 900; letter-spacing: 1.2px; text-transform: uppercase; background: rgba(0,0,0,.35); border: 1px solid rgba(255,255,255,.18); opacity: .9; pointer-events: none; }
.lrMapEmpty{ position: absolute; inset: 0; display: grid; place-items: center; opacity: .28; font-weight: 800; letter-spacing: 1.5px; text-transform: uppercase; font-size: 13px; }
.lrW{ position: absolute; transform: translate(-50%, -50%) scale(1); display: inline-flex; align-items: center; gap: 6px; padding: 5px 12px; border-radius: 999px; font-weight: 800; font-size: 15px; white-space: nowrap; max-width: 92%;
  background: rgba(255,255,255,.14); border: 1px solid rgba(255,255,255,.3); box-shadow: 0 4px 10px rgba(0,0,0,.25); animation: lrWPop .45s cubic-bezier(.2,1.6,.4,1) both;
  transition: transform .7s cubic-bezier(.2,1.5,.4,1), background .6s ease, border-color .6s ease, color .6s ease, opacity .6s ease; transition-delay: calc(var(--i, 0) * 45ms); }
.lrW > span{ overflow: hidden; text-overflow: ellipsis; }
.lrW em{ font-style: normal; font-weight: 900; }
.lrW.mine{ box-shadow: 0 0 0 2px rgba(63,224,245,.55), 0 4px 10px rgba(0,0,0,.25); }
.lrW.tiny{ font-size: 12px; padding: 3px 9px; }
.lrW.ok.go{ transform: translate(-50%, -50%) scale(1.14); background: rgba(20,130,72,.78); border-color: rgba(100,240,160,.9); color: #e2ffee; z-index: 3; }
.lrW.bad.go{ transform: translate(-50%, -50%) scale(.8); background: rgba(140,26,22,.65); border-color: rgba(255,100,88,.8); color: #ffd6d1; opacity: .88; }
.lrW.dup.go{ transform: translate(-50%, -50%) scale(.85); background: rgba(150,100,20,.6); border-color: rgba(255,200,90,.7); color: #ffe9bd; opacity: .88; }
@keyframes lrWPop{ from{ opacity: 0; transform: translate(-50%, -50%) scale(.3); } }
.lrW.bad.go.appealable{ transform: translate(-50%, -50%) scale(.98); cursor: pointer; opacity: 1; box-shadow: 0 0 0 2px rgba(255,210,63,.7), 0 0 18px rgba(255,210,63,.35); z-index: 4; }
.lrW.bad.go.appealable:hover{ transform: translate(-50%, -50%) scale(1.08); }
.lrW.bad.go.pending{ transform: translate(-50%, -50%) scale(1.06); background: rgba(150,100,20,.78); border-color: #ffd23f; color: #fff2cf; opacity: 1; z-index: 5; animation: lrPulse 1.1s ease-in-out infinite alternate; }
@keyframes lrPulse{ from{ box-shadow: 0 0 0 0 rgba(255,210,63,.55); } to{ box-shadow: 0 0 0 7px rgba(255,210,63,0); } }
.lrVotesBox{ display: inline-flex; align-items: center; gap: 4px; margin-left: 2px; }
.lrVotesBox small{ font-size: 12px; font-weight: 800; }
.lrThumb{ font: inherit; font-size: 13px; font-weight: 900; color: #fff; padding: 2px 8px; border-radius: 999px; cursor: pointer; background: rgba(255,255,255,.16); border: 1px solid rgba(255,255,255,.35); }
.lrThumb:hover{ background: rgba(255,255,255,.28); }
.lrThumb.on{ background: #ffd23f; color: #2a1200; border-color: #fff; }
.lrAppealHint{ text-align: center; font-size: 13px; font-weight: 800; color: #ffe08a; animation: lrIn .4s ease both; }
.lrAppealHint.vote{ color: #fff; }
.lrMineHead{ flex: none; text-align: center; font-weight: 800; font-size: 13px; padding: 8px 14px; border-radius: 16px; background: rgba(125,255,169,.14); border: 1px solid rgba(125,255,169,.45); }
.lrMineHead b{ display: block; color: #7dffa9; font-family: var(--font-display); font-size: 26px; line-height: 1; }
.lrLegend{ display: flex; gap: 8px; justify-content: center; flex-wrap: wrap; font-size: 12.5px; font-weight: 800; }
.lrLegend span{ padding: 3px 11px; border-radius: 999px; border: 1px solid; }
.lrLegend .ok{ color: #8dffb8; background: rgba(20,110,64,.4); border-color: rgba(90,230,150,.5); }
.lrLegend .bad{ color: #ff9d94; background: rgba(130,24,20,.4); border-color: rgba(255,100,88,.5); }
.lrLegend .dup{ color: #ffd88a; background: rgba(150,100,20,.4); border-color: rgba(255,200,90,.5); }

/* Pulte der Spieler (wie in der Buzzer-Arena: Figuren auf Blöcken, die mit den Punkten wachsen) */
.lrPodia{ position: relative; display: flex; align-items: flex-end; justify-content: center; gap: clamp(4px, 1vw, 12px); margin: 0 -14px; padding: 0 14px 0; min-height: calc(var(--base) + var(--H) + 74px); }
.lrPod{ position: relative; flex: 1 1 0; max-width: 104px; min-width: 0; display: flex; flex-direction: column; align-items: center; z-index: 2; }
.lrFigure{ position: relative; z-index: 2; margin-bottom: -4px; transition: transform .3s ease; }
.lrFigure img{ display: block; filter: drop-shadow(0 6px 8px rgba(0,0,0,.45)); }
.lrBlock{ width: 100%; position: relative; display: grid; align-content: start; justify-items: center; gap: 2px; padding-top: 8px; border-radius: 12px 12px 4px 4px;
  background: linear-gradient(180deg, rgba(255,255,255,.26), rgba(255,255,255,.07)); border: 1px solid rgba(255,255,255,.22); border-bottom: 0;
  transition: height .9s cubic-bezier(.22,1,.36,1), background .3s ease, box-shadow .3s ease; box-shadow: 0 -4px 20px rgba(0,0,0,.25); }
.lrName{ max-width: 94%; font-size: 12px; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: .92; }
.lrScore{ font-family: var(--font-display); font-weight: 900; font-size: 24px; line-height: 1; color: #ffe08a; }
.lrPod.me .lrBlock{ border-color: #3fe0f5; box-shadow: 0 -4px 20px rgba(0,0,0,.25), 0 0 0 2px rgba(63,224,245,.35); }
.lrPod.done .lrBlock{ background: linear-gradient(180deg, rgba(60,200,120,.5), rgba(60,200,120,.12)); border-color: rgba(100,230,150,.8); }
.lrPod.done .lrFigure{ animation: lrHop .5s ease-in-out 2 alternate; }
@keyframes lrHop{ to{ transform: translateY(-8px); } }
.lrBadge{ position: absolute; top: -30px; z-index: 5; min-width: 26px; height: 26px; padding: 0 6px; border-radius: 999px; display: grid; place-items: center; font-size: 14px; font-weight: 900; background: rgba(0,0,0,.55); border: 1px solid rgba(255,255,255,.35); animation: lrPop .3s cubic-bezier(.2,1.6,.4,1); }
.lrBadge.ok{ background: rgba(20,150,80,.9); border-color: #7dffa9; }
.lrBadge.vote{ background: rgba(255,210,63,.95); color: #2a1200; border-color: #fff; }
.lrBadge.type{ animation: lrTyping 1s ease-in-out infinite alternate; }
@keyframes lrTyping{ from{ transform: translateY(0); } to{ transform: translateY(-4px); } }
.lrGain{ position: absolute; top: -34px; z-index: 6; font-family: var(--font-display); font-weight: 900; font-size: 24px; color: #7dffa9; text-shadow: 0 2px 8px rgba(0,0,0,.6); animation: lrRiseUp 1.8s ease-out forwards; }
@keyframes lrRiseUp{ 0%{ opacity: 0; transform: translateY(14px) scale(.6); } 20%{ opacity: 1; transform: translateY(0) scale(1.2); } 100%{ opacity: 0; transform: translateY(-54px) scale(1); } }

/* Wertungs-Show */
.lrShow{ position: fixed; inset: 0; z-index: 50; display: grid; grid-template-rows: auto 1fr auto; padding: 18px 18px 20px; overflow: hidden; animation: lrShowIn .6s ease both;
  background: radial-gradient(ellipse 55% 45% at 50% -5%, rgba(255,214,120,.26), transparent 70%), radial-gradient(ellipse 40% 60% at 12% 30%, rgba(255,70,140,.12), transparent 70%),
              radial-gradient(ellipse 40% 60% at 88% 30%, rgba(90,120,255,.14), transparent 70%), linear-gradient(180deg, #1f1033 0%, #120a22 55%, #0a0614 100%); }
.lrShow.win{ animation: lrShowIn .6s ease both, lrFlash 1.4s ease .1s; }
@keyframes lrShowIn{ from{ opacity: 0; } }
@keyframes lrFlash{ 0%{ filter: brightness(1); } 12%{ filter: brightness(2.1); } 100%{ filter: brightness(1); } }
.lrSkip{ position: absolute; top: 14px; right: 80px; z-index: 5; }
.lrShowHead{ text-align: center; padding-top: 6px; }
.lrShowHead small{ font-size: 12px; font-weight: 900; letter-spacing: 2px; text-transform: uppercase; opacity: .7; }
.lrShowHead h2{ margin: 2px 0 0; font-family: var(--font-display); font-weight: 900; font-size: clamp(26px, 4.4vw, 44px); }
.lrStage{ display: grid; place-items: center; min-height: 0; }
.lrRollTitle{ font-family: var(--font-display); font-size: clamp(26px, 5vw, 52px); font-weight: 900; animation: lrRoll .35s ease-in-out infinite alternate; }
@keyframes lrRoll{ from{ transform: scale(1) rotate(-1.5deg); } to{ transform: scale(1.06) rotate(1.5deg); } }
.lrBig{ display: grid; justify-items: center; gap: 10px; animation: lrBig .7s cubic-bezier(.2,1.6,.4,1) both; }
@keyframes lrBig{ from{ opacity: 0; transform: scale(.3) translateY(60px); } }
.lrBigPlace{ font-size: clamp(18px, 3vw, 28px); font-weight: 900; letter-spacing: 3px; text-transform: uppercase; color: #ffe08a; }
.lrBigAvatar{ position: relative; border-radius: 50%; display: grid; place-items: center; background: radial-gradient(circle at 40% 35%, rgba(255,226,122,.55), rgba(255,170,30,.15) 70%); box-shadow: 0 0 0 5px #ffd23f, 0 0 calc(20px + 60px * var(--lv)) rgba(255,210,63,.6); }
.lrBigAvatar img{ border-radius: 50%; }
.lrCrown{ position: absolute; top: -34px; font-size: 52px; animation: lrCrown 1s ease-in-out infinite alternate; }
@keyframes lrCrown{ from{ transform: rotate(-8deg) translateY(0); } to{ transform: rotate(8deg) translateY(-6px); } }
.lrBigName{ font-family: var(--font-display); font-weight: 900; font-size: clamp(30px, 6vw, 64px); line-height: 1; text-align: center; overflow-wrap: anywhere; }
.lrBig.winner .lrBigName{ background: linear-gradient(180deg, #fff6d6, #ffc23a 55%, #ff8a1c); -webkit-background-clip: text; background-clip: text; color: transparent; filter: drop-shadow(0 4px 16px rgba(255,150,30,.6)); }
.lrBigPts{ font-family: var(--font-display); font-weight: 900; font-size: clamp(34px, 6vw, 60px); color: #ffe08a; }
.lrBigPts small{ font-size: .38em; opacity: .75; margin-left: 4px; }
.lrSoFar{ list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; max-height: 22vh; overflow: hidden; }
.lrSoFar li{ padding: 5px 12px; border-radius: 999px; font-size: 13px; font-weight: 800; background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); }
.lrSoFar li span{ opacity: .6; margin-right: 3px; }
.lrSoFar li b{ color: #ffe08a; margin-left: 4px; }
.lrFinal{ list-style: none; margin: 0 auto; padding: 8px 0; display: grid; gap: 8px; width: min(620px, 100%); align-content: center; overflow: auto; }
.lrFinal li{ display: flex; align-items: center; gap: 12px; padding: 10px 16px; border-radius: 18px; background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.14); animation: lrWPop .5s cubic-bezier(.2,1.5,.4,1) both; animation-delay: calc(var(--i) * 70ms); }
.lrFinal li.first{ background: linear-gradient(160deg, rgba(255,210,63,.32), rgba(255,140,40,.14)); border-color: #ffd23f; box-shadow: 0 0 30px rgba(255,210,63,.3); }
.lrFinal li.me{ outline: 2px solid rgba(63,224,245,.6); }
.lrFinal b{ flex: 1; font-size: 18px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.lrPlace{ flex: none; width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 14px; background: rgba(255,255,255,.14); }
.lrFinalPts{ font-family: var(--font-display); font-weight: 900; font-size: 26px; color: #ffe08a; }
.lrFinalPts small{ font-size: 12px; opacity: .7; margin-left: 3px; font-family: inherit; }

@media (max-width: 640px){
  .lrMain{ gap: 2px; padding-top: 10px; }
  .lrHead{ gap: 6px; }
  .lrCount{ margin-left: 0; padding: 4px 10px; }
  .lrGoal{ font-size: 12px; padding: 4px 10px; }
  .lrScene{ gap: 8px; }
  .lrCell{ font-size: 68px; }
  .lrReelWrap{ height: 116px; }
  .lrCab{ padding: 8px 8px 6px; border-radius: 22px; }
  .lrPanel{ padding: 9px 12px; gap: 12px; border-radius: 20px; }
  .lrLetter{ width: 62px; height: 62px; font-size: 42px; border-radius: 18px; }
  .lrPanelText h1, .lrPanelText h2{ font-size: 22px; }
  .lrPanelText span{ font-size: 12px; }
  .lrRing{ width: 52px; height: 52px; }
  .lrRingNum{ font-size: 19px; }
  .lrInput{ height: 46px; font-size: 16px; }
  .lrAdd{ height: 46px; }
  .lrVoteGrid{ grid-template-columns: 1fr; gap: 8px; }
  .lrVoteCard{ min-height: 0; grid-template-columns: auto 1fr auto; padding: 10px 14px 10px 40px; justify-items: start; text-align: left; gap: 10px; border-radius: 18px; }
  .lrVoteIcon{ width: 44px; height: 44px; font-size: 24px; }
  .lrVoteName{ text-align: left; }
  .lrMap{ --rh: 42px; }
  .lrW{ font-size: 13px; padding: 4px 10px; }
  .lrScore{ font-size: 16px; }
  .lrName{ font-size: 9.5px; }
  .lrPodia{ gap: 3px; }
  .lrSkip{ right: 70px; }
}
@media (prefers-reduced-motion: reduce){
  .lrCell.hit, .lrW, .lrVotes.rise, .lrBig, .lrRollTitle, .lrFinal li, .lrCrown, .lrLamps i, .lrRing.hot .lrRingNum, .lrPod.done .lrFigure, .lrBadge, .lrGain, .lrScene{ animation: none !important; }
  .lrW.go{ transition: none; }
}
`;
