import React from "react";

export default function AuthLayout({
                                       children,
                                   }: {
    children: React.ReactNode;
}) {
    return (
        <main className="min-h-screen flex items-center justify-center">
            <div className="w-full max-w-md">{children}</div>
        </main>
    );
}
