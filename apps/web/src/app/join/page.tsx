import JoinClient from "./JoinClient";

export default function Page({ searchParams }: { searchParams: { code?: string } }) {
    return <JoinClient initialCode={searchParams.code ?? ""} />;
}