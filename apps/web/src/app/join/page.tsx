import JoinClient from "./JoinClient";

export default async function JoinPage({
                                           searchParams,
                                       }: {
    searchParams: Promise<{ code?: string }>;
}) {
    const sp = await searchParams;
    const initialCode = (sp.code ?? "").toString();
    return <JoinClient initialCode={initialCode} />;
}