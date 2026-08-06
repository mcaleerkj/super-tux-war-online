import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const headers = { Origin: "http://localhost", "Content-Type": "application/json" };
const body = JSON.stringify({ protocol_version: 1 });

describe("room service", () => {
  it("creates one host and one guest, then closes the room", async () => {
    const created = await SELF.fetch("https://example.test/v1/rooms", { method: "POST", headers, body });
    expect(created.status).toBe(200);
    const host = await created.json() as Record<string, unknown>;
    expect(host.peer_id).toBe(1);
    expect(String(host.room_code)).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    expect(Array.isArray(host.ice_servers)).toBe(true);
    expect(String(host.role_secret).length).toBeGreaterThan(20);

    const joinUrl = `https://example.test/v1/rooms/${host.room_code}/join`;
    const joined = await SELF.fetch(joinUrl, { method: "POST", headers, body });
    expect(joined.status).toBe(200);
    const guest = await joined.json() as Record<string, unknown>;
    expect(guest.peer_id).toBe(2);
    expect(String(guest.signal_ticket).length).toBeGreaterThan(20);

    const third = await SELF.fetch(joinUrl, { method: "POST", headers, body });
    expect(third.status).toBe(409);
  });

  it("rejects incompatible clients and untrusted origins", async () => {
    const oldClient = await SELF.fetch("https://example.test/v1/rooms", {
      method: "POST",
      headers,
      body: JSON.stringify({ protocol_version: 99 }),
    });
    expect(oldClient.status).toBe(400);

    const wrongOrigin = await SELF.fetch("https://example.test/v1/rooms", {
      method: "POST",
      headers: { ...headers, Origin: "https://evil.example" },
      body,
    });
    expect(wrongOrigin.status).toBe(403);
  });
});
