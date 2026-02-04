export function GameHUD({ children }: { children: React.ReactNode }) {
    return (
        <div className="flex-1 flex flex-col items-center justify-center">
            {children}
        </div>
    );
}
