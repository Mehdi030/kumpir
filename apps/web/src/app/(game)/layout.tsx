"use client";

import { usePathname } from "next/navigation";
import { RequireAuth } from "@/components/RequireAuth";

export default function GameLayout({ children }: { children: React.ReactNode }) {
    const pathname = usePathname();
    return <RequireAuth nextPath={pathname}>{children}</RequireAuth>;
}
