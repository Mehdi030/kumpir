"use client";

import { PlayerList } from "./PlayerList";
import { PotatoStatus } from "./PotatoStatus";
import { HeatIndicator } from "./HeatIndicator";
import { PassButton } from "./PassButton";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

type HeatLevel = "low" | "mid" | "high";

type GameBoardProps = {
    lobbyCode: string;
    holderPlayerId: string | null;
    players: Player[];
    mePlayerId: string | null;
    heatLevel: HeatLevel;
    onPass: () => void;
};

export function GameBoard({
                              lobbyCode,
                              holderPlayerId,
                              players,
                              mePlayerId,
                              heatLevel,
                              onPass,
                          }: GameBoardProps) {
    const isMeHolder = !!mePlayerId && mePlayerId === holderPlayerId;

    return (
        <main className="container">
            <div className="landingWrap">
                <section className="card" aria-label="Game">
                    {/* Header */}
                    <div
                        style={{
                            display: "flex",
                            justifyContent: "space-between",
                            alignItems: "center",
                            gap: 12,
                        }}
                    >
                        <div>
                            <h1 className="h1" style={{ marginBottom: 4 }}>
                                🥔 Kumpir
                            </h1>
                            <div className="opacity-70">Lobby {lobbyCode}</div>
                        </div>

                        <HeatIndicator level={heatLevel} />
                    </div>

                    <div className="divider" />

                    {/* Status */}
                    <PotatoStatus isHolder={isMeHolder} />

                    {/* Players */}
                    <PlayerList
                        players={players}
                        holderPlayerId={holderPlayerId}
                        mePlayerId={mePlayerId}
                    />

                    {/* Action */}
                    <div style={{ display: "flex", justifyContent: "center", marginTop: 18 }}>
                        <PassButton disabled={!isMeHolder} onClick={onPass} />
                    </div>
                </section>
            </div>
        </main>
    );
}