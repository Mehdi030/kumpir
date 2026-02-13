"use client";

type Player = {
    player_id: string;
    name: string;
    is_alive: boolean;
};

type Props = {
    players: Player[];
    holderPlayerId: string | null;
    mePlayerId: string | null;
};

export function PlayerList({
                               players,
                               holderPlayerId,
                               mePlayerId,
                           }: Props) {
    return (
        <div className="flex flex-col gap-2 mt-4">
            {players.map((p) => {
                const isHolder = p.player_id === holderPlayerId;
                const isMe = p.player_id === mePlayerId;

                return (
                    <div
                        key={p.player_id}
                        className={`rounded-xl px-4 py-2 transition
              ${isHolder ? "bg-orange-500/30 border border-orange-400" : "bg-black/20"}
              ${!p.is_alive ? "opacity-40 line-through" : ""}
            `}
                    >
                        <div className="flex justify-between items-center">
              <span className="font-semibold">
                {p.name}
                  {isMe && " (Du)"}
              </span>

                            {isHolder && <span>🥔</span>}
                        </div>
                    </div>
                );
            })}
        </div>
    );
}