export function GameShell({ children }: { children: React.ReactNode }) {
    return (
        <div className="min-h-screen">
            <div className="mx-auto w-full max-w-6xl px-4 sm:px-6 lg:px-8 py-6">
                {children}
            </div>
        </div>
    );
}