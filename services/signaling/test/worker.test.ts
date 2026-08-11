import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

// Exercises the committed production allowlist in wrangler.jsonc, so a bad
// ALLOWED_ORIGINS value fails CI instead of the live game.
const headers = { Origin: "https://mcaleerkj.github.io", "Content-Type": "application/json" };
const body = JSON.stringify({ protocol_version: 1 });

async function createRoom(): Promise<Record<string, unknown>> {
  const created = await SELF.fetch("https://example.test/v1/rooms", { method: "POST", headers, body });
  expect(created.status).toBe(200);
  return created.json() as Promise<Record<string, unknown>>;
}

describe("room service", () => {
  it("creates one host and one guest, then closes the room", async () => {
    const host = await createRoom();
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

describe("signaling ticket refresh", () => {
  // Tickets are single-use and burned on connect, so a socket that drops before
  // WebRTC is established can only resume by trading the role secret for a new
  // one. Without this the players must abandon the room code entirely.
  it("issues a fresh ticket to a holder of the role secret", async () => {
    const host = await createRoom();
    const refreshed = await SELF.fetch(`https://example.test/v1/rooms/${host.room_code}/signal-ticket`, {
      method: "POST",
      headers: { ...headers, Authorization: `Bearer ${host.role_secret}` },
      body,
    });
    expect(refreshed.status).toBe(200);

    const ticket = String((await refreshed.json() as Record<string, unknown>).signal_ticket);
    expect(ticket.length).toBeGreaterThan(20);
    expect(ticket).not.toBe(String(host.signal_ticket));
  });

  it("refuses a missing or incorrect role secret", async () => {
    const host = await createRoom();
    const url = `https://example.test/v1/rooms/${host.room_code}/signal-ticket`;

    const anonymous = await SELF.fetch(url, { method: "POST", headers, body });
    expect(anonymous.status).toBe(401);

    const wrongSecret = await SELF.fetch(url, {
      method: "POST",
      headers: { ...headers, Authorization: "Bearer not-the-real-secret" },
      body,
    });
    expect(wrongSecret.status).toBe(401);
  });

  it("refuses to refresh a ticket for a room that never existed", async () => {
    const missing = await SELF.fetch("https://example.test/v1/rooms/ZZZZZZZZ/signal-ticket", {
      method: "POST",
      headers: { ...headers, Authorization: "Bearer anything" },
      body,
    });
    expect(missing.status).toBe(410);
  });
});
