import Link from "next/link";
import { Button } from "@/components/ui/Button";

export default function Home() {
    return (
        <main className="container">
            <div className="card">
                <div className="h1">RELAY</div>
                <p className="p">Browser‑Partyspiel mit 4‑stelligem Lobby‑Code.</p>

                <div className="row" style={{ marginTop: 18 }}>
                    <Link href="/host"><Button>Host</Button></Link>
                    <Link href="/join"><Button variant="secondary">Join</Button></Link>
                </div>
            </div>
        </main>
    );
}
