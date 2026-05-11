export type AchievementTier = "bronze" | "silver" | "gold";

export type Achievement = {
    code: string;
    title: string;
    description: string;
    icon: string;
    tier: AchievementTier;
};

export type PlayerAchievement = {
    user_id: string;
    achievement_code: string;
    unlocked_at: string;
    lobby_id: string | null;
};

export type PlayerLifetimeStats = {
    user_id: string;
    games_played: number;
    wins: number;
    total_passes: number;
    total_clutch_passes: number;
    fastest_pass_ms: number | null;
    total_hold_ms: number;
    best_survival_streak: number;
};

export const TIER_STYLE: Record<AchievementTier, { bg: string; border: string; glow: string }> = {
    bronze: {
        bg: "linear-gradient(135deg, rgba(205,127,50,0.22), rgba(139,75,30,0.32))",
        border: "rgba(205,127,50,0.55)",
        glow: "0 0 20px rgba(205,127,50,0.32)",
    },
    silver: {
        bg: "linear-gradient(135deg, rgba(192,192,192,0.22), rgba(128,128,128,0.32))",
        border: "rgba(220,220,220,0.55)",
        glow: "0 0 22px rgba(220,220,220,0.36)",
    },
    gold: {
        bg: "linear-gradient(135deg, rgba(255,215,0,0.26), rgba(184,134,11,0.40))",
        border: "rgba(255,215,0,0.65)",
        glow: "0 0 28px rgba(255,215,0,0.46)",
    },
};
