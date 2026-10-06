// Wegwerf-Konten für die DB-Tests (laufen innerhalb der Test-Transaktion und werden mit ROLLBACK verworfen).
import { randomUUID } from "node:crypto";
export async function createTestUser(q, username, role = "user") {
    const id = randomUUID();
    await q(
        `insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
         values ($1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $2, '', now(), '{"provider":"email","providers":["email"]}', $3::jsonb, now(), now())`,
        [id, `${username}-${id.slice(0, 8)}@example.invalid`, JSON.stringify({ username })]
    );
    if (role !== "user") await q("update public.profiles set role = $2, is_platform_admin = ($2 = 'admin') where id = $1", [id, role]);
    return id;
}
