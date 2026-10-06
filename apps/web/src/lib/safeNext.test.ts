import { describe, it, expect } from "vitest";
import { safeNextPath } from "./safeNext";

describe("safeNextPath", () => {
    it("lässt interne Pfade durch", () => {
        expect(safeNextPath("/profile")).toBe("/profile");
        expect(safeNextPath("/lobby/AB12?x=1")).toBe("/lobby/AB12?x=1");
        expect(safeNextPath("/auth/reset")).toBe("/auth/reset");
    });

    it("blockt Weiterleitungen auf fremde Seiten", () => {
        for (const bad of ["//evil.com", "/\\evil.com", "https://evil.com", "javascript:alert(1)", "/\\/evil.com", "/%5Cevil", "\\\\evil.com", "/ok\u0000x", "evil.com"]) {
            const out = safeNextPath(bad);
            expect(out.startsWith("//") || out.startsWith("/\\") || /^[a-z]+:/i.test(out)).toBe(false);
        }
        expect(safeNextPath("//evil.com")).toBe("/");
        expect(safeNextPath("/\\evil.com")).toBe("/");
    });

    it("nutzt den Ersatz-Pfad", () => {
        expect(safeNextPath(null, "/host")).toBe("/host");
        expect(safeNextPath("https://x.y", "/verified")).toBe("/verified");
    });
});
