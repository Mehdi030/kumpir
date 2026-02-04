"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";

export function RequireAuth({
                                nextPath,
                                children,
                            }: {
    nextPath: string;
    children: React.ReactNode;
}) {
    const router = useRouter();
    const { user, loading } = useAuth();

    useEffect(() => {
        if (loading) return;
        if (!user) router.replace(`/login?next=${encodeURIComponent(nextPath)}`);
    }, [loading, user, router, nextPath]);

    if (loading) return null;
    if (!user) return null;

    return <>{children}</>;
}
