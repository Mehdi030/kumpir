"use client";

import { useCallback, useState } from "react";

export type Toast = {
    id: number;
    msg: string;
};

type Options = {
    maxVisible?: number;
};

export function useToastStack({ maxVisible = 3 }: Options = {}) {
    const [stack, setStack] = useState<Toast[]>([]);

    const push = useCallback(
        (msg: string, ms = 1800) => {
            const id = (typeof performance !== "undefined" ? performance.now() : Date.now()) + Math.random();
            setStack((prev) => {
                const next = [...prev, { id, msg }];
                return next.length > maxVisible ? next.slice(next.length - maxVisible) : next;
            });
            window.setTimeout(() => {
                setStack((prev) => prev.filter((t) => t.id !== id));
            }, Math.max(400, ms));
        },
        [maxVisible]
    );

    const clear = useCallback(() => setStack([]), []);

    return { toasts: stack, pushToast: push, clearToasts: clear };
}
