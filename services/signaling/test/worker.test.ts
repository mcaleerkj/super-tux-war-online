import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { HOST_PEER_ID, MAX_PEERS, PROTOCOL_VERSION } from "../src/protocol";

// Exercises the committed production allowlist in wrangler.jsonc, so a bad
// ALLOWED_ORIGINS value fails CI instead of the live game.
const ORIGIN = "https://mcaleerkj.github.io";
const body = JSON.stringify({ protocol_version: PROTOCOL_VERSION });

// The rate limiter is really enforced in this harness, keyed on CF-Connecting-IP
// and shared across the whole file. Without a distinct address per caller the
// suite trips its own 5-rooms-per-minute limit as soon as tests are added.
let addresses = 0;
function headers(extra: Record<string, string> = {}): Record<string, string> {
  addresses += 1;
  return { Origin: ORIGIN, "Content-Type": "application/json", "CF-Connecting-IP": `192.0.2.${addresses % 250}`, ...extra };
}

type Json = Record<string, unknown>;

async function createRoom(): Promise<Json> {
  const created = await SELF.fetch("https://example.test/v1/rooms", { method: "POST", headers: headers(), body });
  expect(created.status).toBe(200);
  return created.json() as Promise<Json>;
}

async function joinRoom(code: unknown): Promise<Response> {
  return SELF.fetch(`https://example.test/v1/rooms/${code}/join`, { method: "POST", headers: headers(), body });
}

async function post(code: unknown, action: string, secret: unknown): Promise<Response> {
  return SELF.fetch(`https://example.test/v1/rooms/${code}/${action}`, {
    method: "POST",
    headers: headers({ Authorization: `Bearer ${secret}` }),
    body,
  });
}

describe("room lifecycle", () => {
  it("seats a host plus five guests and refuses the seventh", async () => {
    const host = await createRoom();
    expect(host.peer_id).toBe(HOST_PEER_ID);
    expect(host.role).toBe("host");
    expect(String(host.room_code)).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    expect(host.max_peers).toBe(MAX_PEERS);
    expect(Array.isArray(host.ice_servers)).toBe(true);

    const seen = new Set<number>([HOST_PEER_ID]);
    for (let index = 1; index < MAX_PEERS; index++) {
      const joined = await joinRoom(host.room_code);
      expect(joined.status).toBe(200);
      const guest = await joined.json() as Json;
      expect(guest.role).toBe("guest");
      expect(seen.has(guest.peer_id as number)).toBe(false);
      seen.add(guest.peer_id as number);
    }
    expect(seen.size).toBe(MAX_PEERS);

    const overflow = await joinRoom(host.room_code);
    expect(overflow.status).toBe(409);
    expect((await overflow.json() as Json).reason).toBe("full");
  });

  it("never reuses the peer id of someone who left", async () => {
    const host = await createRoom();
    const first = await (await joinRoom(host.room_code)).json() as Json;
    const second = await (await joinRoom(host.room_code)).json() as Json;

    expect((await post(host.room_code, "leave", first.role_secret)).status).toBe(204);

    // The freed seat is reusable, but the id is not: a stale reference to the
    // departed peer must never resolve to their replacement.
    const replacement = await (await joinRoom(host.room_code)).json() as Json;
    expect(replacement.peer_id).not.toBe(first.peer_id);
    expect(replacement.peer_id).not.toBe(second.peer_id);
  });

  it("rejects incompatible clients and untrusted origins", async () => {
    const oldClient = await SELF.fetch("https://example.test/v1/rooms", {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ protocol_version: PROTOCOL_VERSION - 1 }),
    });
    expect(oldClient.status).toBe(400);

    const wrongOrigin = await SELF.fetch("https://example.test/v1/rooms", {
      method: "POST",
      headers: { ...headers(), Origin: "https://evil.example" },
      body,
    });
    expect(wrongOrigin.status).toBe(403);
  });
});

describe("match lock", () => {
  it("closes the room to new joins once the host starts", async () => {
    const host = await createRoom();
    await joinRoom(host.room_code);

    const locked = await post(host.room_code, "lock", host.role_secret);
    expect(locked.status).toBe(200);
    const roster = await locked.json() as Json;
    expect((roster.peers as unknown[]).length).toBe(2);

    const late = await joinRoom(host.room_code);
    expect(late.status).toBe(409);
    expect((await late.json() as Json).reason).toBe("locked");

    // Idempotent, so a retry after a dropped response is safe.
    expect((await post(host.room_code, "lock", host.role_secret)).status).toBe(200);
  });

  it("refuses to lock on a guest's authority", async () => {
    const host = await createRoom();
    const guest = await (await joinRoom(host.room_code)).json() as Json;
    expect((await post(host.room_code, "lock", guest.role_secret)).status).toBe(401);
    expect((await post(host.room_code, "lock", "not-the-real-secret")).status).toBe(401);
    // And the room is still open, so a failed lock did not half-apply.
    expect((await joinRoom(host.room_code)).status).toBe(200);
  });

  it("closes the whole room when the host leaves", async () => {
    const host = await createRoom();
    await joinRoom(host.room_code);
    expect((await post(host.room_code, "leave", host.role_secret)).status).toBe(204);
    expect((await joinRoom(host.room_code)).status).toBe(410);
    expect((await post(host.room_code, "signal-ticket", host.role_secret)).status).toBe(410);
  });
});

describe("signaling tickets", () => {
  it("issues a fresh ticket to the holder of a role secret", async () => {
    const host = await createRoom();
    const refreshed = await post(host.room_code, "signal-ticket", host.role_secret);
    expect(refreshed.status).toBe(200);

    const issued = await refreshed.json() as Json;
    expect(String(issued.signal_ticket).length).toBeGreaterThan(20);
    expect(issued.signal_ticket).not.toBe(host.signal_ticket);
    // Echoing identity back lets a reconnecting client re-assert who it is
    // rather than trusting cached state.
    expect(issued.peer_id).toBe(HOST_PEER_ID);
    expect(issued.role).toBe("host");
  });

  it("is per peer, not per role", async () => {
    const host = await createRoom();
    const first = await (await joinRoom(host.room_code)).json() as Json;
    const second = await (await joinRoom(host.room_code)).json() as Json;

    const issued = await (await post(host.room_code, "signal-ticket", second.role_secret)).json() as Json;
    expect(issued.peer_id).toBe(second.peer_id);
    expect(issued.peer_id).not.toBe(first.peer_id);
  });

  it("refuses a missing or incorrect role secret", async () => {
    const host = await createRoom();
    const anonymous = await SELF.fetch(`https://example.test/v1/rooms/${host.room_code}/signal-ticket`, {
      method: "POST",
      headers: headers(),
      body,
    });
    expect(anonymous.status).toBe(401);
    expect((await post(host.room_code, "signal-ticket", "wrong")).status).toBe(401);
  });

  it("refuses a room that never existed", async () => {
    expect((await post("ZZZZZZZZ", "signal-ticket", "anything")).status).toBe(410);
  });
});

// ---------------------------------------------------------------------------
// Signalling relay. With one possible recipient the room could infer the
// target; with five it cannot, and `from` becomes the only thing separating
// one guest from impersonating another to the host. These are the tests that
// keep that honest.
// ---------------------------------------------------------------------------

type Socket = { ws: WebSocket; inbox: Json[] };

async function openSocket(code: unknown, ticket: unknown): Promise<Socket> {
  const response = await SELF.fetch(
    `https://example.test/v1/rooms/${code}/signal?v=${PROTOCOL_VERSION}&ticket=${encodeURIComponent(String(ticket))}`,
    { headers: { Upgrade: "websocket", Origin: ORIGIN } },
  );
  expect(response.status).toBe(101);
  const ws = response.webSocket as unknown as WebSocket;
  const inbox: Json[] = [];
  ws.addEventListener("message", (event: MessageEvent) => { inbox.push(JSON.parse(String(event.data)) as Json); });
  ws.accept();
  return { ws, inbox };
}

async function settle(): Promise<void> {
  for (let i = 0; i < 12; i++) await scheduler.wait(1);
}

function typesOf(socket: Socket): string[] {
  return socket.inbox.map((m) => String(m.type));
}

describe("signalling relay", () => {
  it("greets each peer with a roster scoped to what it may know", async () => {
    const host = await createRoom();
    const guest = await (await joinRoom(host.room_code)).json() as Json;

    const hostSocket = await openSocket(host.room_code, host.signal_ticket);
    const guestSocket = await openSocket(host.room_code, guest.signal_ticket);
    await settle();

    const hostWelcome = hostSocket.inbox.find((m) => m.type === "welcome") as Json;
    expect(hostWelcome.peer_id).toBe(HOST_PEER_ID);
    expect(hostWelcome.role).toBe("host");

    const guestWelcome = guestSocket.inbox.find((m) => m.type === "welcome") as Json;
    expect(guestWelcome.peer_id).toBe(guest.peer_id);
    // A guest is told only about the host, so the room leaks nothing about
    // other guests over the signalling channel.
    expect((guestWelcome.peers as Json[]).every((p) => p.role === "host")).toBe(true);

    // The host learns which guest arrived, which is what lets it address a
    // per-guest offer at all.
    const joined = hostSocket.inbox.find((m) => m.type === "peer_joined") as Json;
    expect(joined.peer_id).toBe(guest.peer_id);
  });

  it("delivers only to the addressed peer", async () => {
    const host = await createRoom();
    const a = await (await joinRoom(host.room_code)).json() as Json;
    const b = await (await joinRoom(host.room_code)).json() as Json;

    const hostSocket = await openSocket(host.room_code, host.signal_ticket);
    const socketA = await openSocket(host.room_code, a.signal_ticket);
    const socketB = await openSocket(host.room_code, b.signal_ticket);
    await settle();
    socketA.inbox.length = 0;
    socketB.inbox.length = 0;

    hostSocket.ws.send(JSON.stringify({ type: "offer", to: b.peer_id, sdp: "v=0 for-b" }));
    await settle();

    const delivered = socketB.inbox.find((m) => m.type === "offer") as Json;
    expect(delivered.sdp).toBe("v=0 for-b");
    expect(delivered.from).toBe(HOST_PEER_ID);
    // The silence of the unaddressed peer is the actual assertion here.
    expect(typesOf(socketA)).not.toContain("offer");
  });

  it("stamps `from` itself and refuses a client that supplies one", async () => {
    const host = await createRoom();
    const a = await (await joinRoom(host.room_code)).json() as Json;
    const b = await (await joinRoom(host.room_code)).json() as Json;

    const hostSocket = await openSocket(host.room_code, host.signal_ticket);
    await openSocket(host.room_code, a.signal_ticket);
    const socketB = await openSocket(host.room_code, b.signal_ticket);
    await settle();
    hostSocket.inbox.length = 0;

    // Guest B claims to be guest A.
    socketB.ws.send(JSON.stringify({
      type: "ice", to: HOST_PEER_ID, from: a.peer_id, media: "0", index: 0, candidate: "spoofed",
    }));
    await settle();
    expect(typesOf(hostSocket)).not.toContain("ice");
    expect(typesOf(socketB)).toContain("error");

    socketB.inbox.length = 0;
    socketB.ws.send(JSON.stringify({ type: "ice", to: HOST_PEER_ID, media: "0", index: 0, candidate: "honest" }));
    await settle();
    const relayed = hostSocket.inbox.find((m) => m.type === "ice") as Json;
    expect(relayed.from).toBe(b.peer_id);
    expect(relayed.candidate).toBe("honest");
  });

  it("keeps guests from reaching each other and from offering", async () => {
    const host = await createRoom();
    const a = await (await joinRoom(host.room_code)).json() as Json;
    const b = await (await joinRoom(host.room_code)).json() as Json;

    await openSocket(host.room_code, host.signal_ticket);
    const socketA = await openSocket(host.room_code, a.signal_ticket);
    const socketB = await openSocket(host.room_code, b.signal_ticket);
    await settle();
    socketA.inbox.length = 0;
    socketB.inbox.length = 0;

    socketA.ws.send(JSON.stringify({ type: "ice", to: b.peer_id, media: "0", index: 0, candidate: "sideways" }));
    socketA.ws.send(JSON.stringify({ type: "offer", to: HOST_PEER_ID, sdp: "v=0" }));
    await settle();

    expect(typesOf(socketB)).not.toContain("ice");
    expect(typesOf(socketA).filter((t) => t === "error").length).toBe(2);
  });

  it("strips anything the sender tried to smuggle alongside the payload", async () => {
    const host = await createRoom();
    const guest = await (await joinRoom(host.room_code)).json() as Json;
    const hostSocket = await openSocket(host.room_code, host.signal_ticket);
    const guestSocket = await openSocket(host.room_code, guest.signal_ticket);
    await settle();
    hostSocket.inbox.length = 0;

    guestSocket.ws.send(JSON.stringify({
      type: "ice", to: HOST_PEER_ID, media: "0", index: 0, candidate: "c", evil: "payload",
    }));
    await settle();
    const relayed = hostSocket.inbox.find((m) => m.type === "ice") as Json;
    expect(relayed).toBeDefined();
    expect("evil" in relayed).toBe(false);
  });

  it("turns away a socket on the wrong protocol version", async () => {
    const host = await createRoom();
    const stale = await SELF.fetch(
      `https://example.test/v1/rooms/${host.room_code}/signal?v=1&ticket=${host.signal_ticket}`,
      { headers: { Upgrade: "websocket", Origin: ORIGIN } },
    );
    expect(stale.status).toBe(400);
  });
});
