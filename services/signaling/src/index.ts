import { DurableObject } from "cloudflare:workers";
import {
  HOST_PEER_ID,
  MAX_PEERS,
  MAX_PEER_ID,
  MAX_SIGNAL_BYTES,
  PROTOCOL_VERSION,
  ROOM_TTL_MS,
  TICKET_TTL_MS,
  TURN_TTL_SECONDS,
  UNJOINED_TTL_MS,
  isRoomCode,
  isSignalMessage,
  normalizeRoomCode,
  randomRoomCode,
  randomToken,
  sha256,
  type PeerRecord,
  type Role,
  type RoomRecord,
  type SocketAttachment,
} from "./protocol";

interface Env {
  ROOMS: DurableObjectNamespace<GameRoom>;
  CREATE_RATE_LIMITER: RateLimit;
  JOIN_RATE_LIMITER: RateLimit;
  ALLOWED_ORIGINS: string;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const origin = request.headers.get("Origin");
    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }), origin, env);
    if (!isAllowedOrigin(origin, env)) return json({ error: "Origin not allowed." }, 403, origin, env);

    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, protocol_version: PROTOCOL_VERSION, max_peers: MAX_PEERS }, 200, origin, env);
    }
    if (request.method === "POST" && url.pathname === "/v1/rooms") {
      const limited = await env.CREATE_RATE_LIMITER.limit({ key: clientKey(request) });
      if (!limited.success) return json({ error: "Too many rooms created. Try again shortly." }, 429, origin, env);
      const protocolError = await validateProtocolBody(request);
      if (protocolError) return json({ error: protocolError }, 400, origin, env);
      return cors(await createRoom(request, env), origin, env);
    }
    if (parts.length >= 3 && parts[0] === "v1" && parts[1] === "rooms") {
      const roomCode = normalizeRoomCode(parts[2]);
      if (!isRoomCode(roomCode)) return json({ error: "Invalid room code." }, 400, origin, env);
      const stub = env.ROOMS.get(env.ROOMS.idFromName(roomCode));
      const action = parts[3];

      if (request.method === "POST" && (action === "join" || action === "signal-ticket" || action === "lock" || action === "leave")) {
        const limited = await env.JOIN_RATE_LIMITER.limit({ key: clientKey(request) });
        if (!limited.success) return json({ error: "Too many requests. Try again shortly." }, 429, origin, env);
        const protocolError = await validateProtocolBody(request);
        if (protocolError) return json({ error: protocolError }, 400, origin, env);
        if (action === "join") return cors(await joinRoom(request, env, stub, roomCode), origin, env);
        if (action === "signal-ticket") return cors(await refreshTicket(request, stub), origin, env);
        return cors(await authorizedRoomAction(request, stub, action), origin, env);
      }
      if (request.method === "GET" && action === "signal") {
        return stub.fetch(new Request(`https://room.internal/signal${url.search}`, request));
      }
    }
    return json({ error: "Not found." }, 404, origin, env);
  },
} satisfies ExportedHandler<Env>;

function clientKey(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "local";
}

async function createRoom(request: Request, env: Env): Promise<Response> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const roomCode = randomRoomCode();
    const roleSecret = randomToken(16);
    const ticket = randomToken(18);
    const stub = env.ROOMS.get(env.ROOMS.idFromName(roomCode));
    const response = await stub.fetch("https://room.internal/create", {
      method: "POST",
      body: JSON.stringify({ secretHash: await sha256(roleSecret), ticketHash: await sha256(ticket) }),
    });
    if (response.status === 409) continue;
    if (!response.ok) return json({ error: "Could not create the room." }, 502);
    return roomResponse(request, env, roomCode, roleSecret, ticket, HOST_PEER_ID, "host");
  }
  return json({ error: "Could not allocate a unique room code." }, 503);
}

async function joinRoom(
  request: Request,
  env: Env,
  stub: DurableObjectStub<GameRoom>,
  roomCode: string,
): Promise<Response> {
  const roleSecret = randomToken(16);
  const ticket = randomToken(18);
  const response = await stub.fetch("https://room.internal/join", {
    method: "POST",
    body: JSON.stringify({ secretHash: await sha256(roleSecret), ticketHash: await sha256(ticket) }),
  });
  if (!response.ok) return new Response(response.body, { status: response.status, headers: response.headers });
  const assigned = await response.json() as { peer_id: number };
  return roomResponse(request, env, roomCode, roleSecret, ticket, assigned.peer_id, "guest");
}

/**
 * Trades a role secret for a fresh single-use ticket. Only the hash reaches the
 * room, so the plaintext ticket never touches durable storage.
 */
async function refreshTicket(request: Request, stub: DurableObjectStub<GameRoom>): Promise<Response> {
  const secret = bearer(request);
  if (secret === null) return json({ error: "Missing role secret." }, 401);
  const ticket = randomToken(18);
  const response = await stub.fetch("https://room.internal/ticket", {
    method: "POST",
    body: JSON.stringify({ secretHash: await sha256(secret), ticketHash: await sha256(ticket) }),
  });
  if (!response.ok) return response;
  const assigned = await response.json() as { peer_id: number; role: Role };
  return json({ signal_ticket: ticket, peer_id: assigned.peer_id, role: assigned.role });
}

async function authorizedRoomAction(
  request: Request,
  stub: DurableObjectStub<GameRoom>,
  action: string,
): Promise<Response> {
  const secret = bearer(request);
  if (secret === null) return json({ error: "Missing role secret." }, 401);
  return stub.fetch(`https://room.internal/${action}`, {
    method: "POST",
    body: JSON.stringify({ secretHash: await sha256(secret) }),
  });
}

function bearer(request: Request): string | null {
  const authorization = request.headers.get("Authorization") ?? "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7) : null;
}

async function roomResponse(
  request: Request,
  env: Env,
  roomCode: string,
  roleSecret: string,
  ticket: string,
  peerId: number,
  role: Role,
): Promise<Response> {
  const requestUrl = new URL(request.url);
  const signalingUrl = `${requestUrl.protocol === "https:" ? "wss:" : "ws:"}//${requestUrl.host}/v1/rooms/${roomCode}/signal`;
  let iceServers: unknown[];
  try {
    iceServers = await generateIceServers(env);
  } catch {
    return json({ error: "Could not issue relay credentials. Please try again." }, 502);
  }
  return json({
    room_code: roomCode,
    peer_id: peerId,
    role,
    host_peer_id: HOST_PEER_ID,
    max_peers: MAX_PEERS,
    role_secret: roleSecret,
    signal_ticket: ticket,
    signaling_url: signalingUrl,
    ice_servers: iceServers,
    expires_at: new Date(Date.now() + ROOM_TTL_MS).toISOString(),
  });
}

async function generateIceServers(env: Env): Promise<unknown[]> {
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
    return [{ urls: ["stun:stun.cloudflare.com:3478"] }];
  }
  const response = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.TURN_API_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
    },
  );
  if (!response.ok) throw new Error(`TURN credential request failed (${response.status})`);
  const value = await response.json() as { iceServers?: unknown[] };
  if (!Array.isArray(value.iceServers)) throw new Error("TURN service returned no ICE servers");
  return value.iceServers;
}

async function validateProtocolBody(request: Request): Promise<string | null> {
  try {
    const body = await request.clone().json() as { protocol_version?: number };
    return body.protocol_version === PROTOCOL_VERSION
      ? null
      : "This game version is out of date. Please refresh the page.";
  } catch {
    return "Invalid JSON body.";
  }
}

function isAllowedOrigin(origin: string | null, env: Env): boolean {
  if (!origin) return true;
  return env.ALLOWED_ORIGINS.split(",").map((value) => value.trim()).some((allowed) =>
    allowed !== "" && (origin === allowed || origin.startsWith(`${allowed}:`))
  );
}

function cors(response: Response, origin: string | null, env: Env): Response {
  const next = new Response(response.body, response);
  if (origin && isAllowedOrigin(origin, env)) next.headers.set("Access-Control-Allow-Origin", origin);
  next.headers.set("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  next.headers.set("Access-Control-Allow-Headers", "Authorization,Content-Type");
  next.headers.set("Vary", "Origin");
  return next;
}

function json(value: unknown, status = 200, origin: string | null = null, env?: Env): Response {
  const response = new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
  return env ? cors(response, origin, env) : response;
}

export class GameRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST") {
      if (url.pathname === "/create") return this.create(request);
      if (url.pathname === "/join") return this.join(request);
      if (url.pathname === "/ticket") return this.ticket(request);
      if (url.pathname === "/lock") return this.lock(request);
      if (url.pathname === "/leave") return this.leave(request);
    }
    if (url.pathname === "/signal" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.connectWebSocket(url);
    }
    return json({ error: "Not found." }, 404);
  }

  async alarm(): Promise<void> {
    this.broadcast(this.ctx.getWebSockets(), { type: "room_closed", reason: "expired" });
    for (const socket of this.ctx.getWebSockets()) socket.close(4003, "Room expired");
    await this.ctx.storage.deleteAll();
  }

  async webSocketMessage(socket: WebSocket, payload: string | ArrayBuffer): Promise<void> {
    const size = typeof payload === "string" ? new TextEncoder().encode(payload).byteLength : payload.byteLength;
    if (size > MAX_SIGNAL_BYTES) {
      socket.send(JSON.stringify({ type: "error", message: "Signaling message too large." }));
      return;
    }
    const attachment = socket.deserializeAttachment() as SocketAttachment | null;
    if (!attachment || attachment.evicted) return;
    let message: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(typeof payload === "string" ? payload : new TextDecoder().decode(payload));
      if (!isSignalMessage(parsed)) {
        socket.send(JSON.stringify({ type: "error", message: "Invalid signaling message." }));
        return;
      }
      message = parsed;
    } catch {
      socket.send(JSON.stringify({ type: "error", message: "Invalid signaling JSON." }));
      return;
    }

    const from = attachment.peerId;
    const to = message.to as number;
    if (to === from) {
      socket.send(JSON.stringify({ type: "error", message: "Cannot signal yourself." }));
      return;
    }
    // Star topology: guests negotiate only with the host, and only the host
    // offers. This means a guest can never address another guest, so the only
    // party that has to trust `from` is the host.
    if (attachment.role === "guest") {
      if (to !== HOST_PEER_ID) {
        socket.send(JSON.stringify({ type: "error", message: "Guests may only signal the host." }));
        return;
      }
      if (message.type === "offer") {
        socket.send(JSON.stringify({ type: "error", message: "Only the host may offer." }));
        return;
      }
    } else if (to === HOST_PEER_ID || message.type === "answer") {
      socket.send(JSON.stringify({ type: "error", message: "Invalid signaling target." }));
      return;
    }

    // Rebuilt field by field rather than forwarded: the incoming object must
    // never be able to smuggle extra keys, least of all its own `from`.
    const relayed = message.type === "ice"
      ? { type: "ice", from, media: message.media, index: message.index, candidate: message.candidate }
      : { type: message.type, from, sdp: message.sdp };
    this.broadcast(this.peerSockets(to), relayed);
  }

  async webSocketClose(socket: WebSocket, _code: number, _reason: string): Promise<void> {
    const attachment = socket.deserializeAttachment() as SocketAttachment | null;
    // An evicted socket belongs to a peer that is reconnecting, so its peers
    // must not be told anyone left. The socket is already closing here;
    // re-closing it with the client's code would throw on reserved codes such
    // as 1006 (abnormal closure on tab close).
    if (!attachment || attachment.evicted) return;
    this.announce(attachment.peerId, attachment.role, "peer_left");
  }

  private async create(request: Request): Promise<Response> {
    if (await this.ctx.storage.get<RoomRecord>("room")) return json({ error: "Room already exists." }, 409);
    const body = await request.json() as { secretHash: string; ticketHash: string };
    const now = Date.now();
    const room: RoomRecord = {
      createdAt: now,
      hardExpiresAt: now + ROOM_TTL_MS,
      nextPeerId: HOST_PEER_ID + 1,
      peers: {
        [String(HOST_PEER_ID)]: {
          role: "host",
          secretHash: body.secretHash,
          ticketHash: body.ticketHash,
          ticketExpiresAt: now + TICKET_TTL_MS,
          joinedAt: now,
        },
      },
    };
    await this.ctx.storage.put("room", room);
    await this.ctx.storage.setAlarm(room.hardExpiresAt);
    return json({ ok: true }, 201);
  }

  private async join(request: Request): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    if (room.lockedAt) return json({ error: "The match has already started.", reason: "locked" }, 409);
    if (Object.keys(room.peers).length === 1 && Date.now() - room.createdAt > UNJOINED_TTL_MS) {
      return json({ error: "Room expired before a friend joined." }, 410);
    }
    if (Object.keys(room.peers).length >= MAX_PEERS) {
      return json({ error: "Room is full.", reason: "full" }, 409);
    }
    if (room.nextPeerId > MAX_PEER_ID) return json({ error: "Room is worn out. Start a new one." }, 409);
    const body = await request.json() as { secretHash: string; ticketHash: string };
    const now = Date.now();
    const peerId = room.nextPeerId;
    room.nextPeerId += 1;
    room.peers[String(peerId)] = {
      role: "guest",
      secretHash: body.secretHash,
      ticketHash: body.ticketHash,
      ticketExpiresAt: now + TICKET_TTL_MS,
      joinedAt: now,
    };
    await this.ctx.storage.put("room", room);
    return json({ peer_id: peerId });
  }

  private async ticket(request: Request): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    const body = await request.json() as { secretHash: string; ticketHash: string };
    const found = this.findBySecret(room, body.secretHash);
    if (!found) return json({ error: "Invalid role secret." }, 401);
    found.peer.ticketHash = body.ticketHash;
    found.peer.ticketExpiresAt = Date.now() + TICKET_TTL_MS;
    await this.ctx.storage.put("room", room);
    return json({ peer_id: found.peerId, role: found.peer.role });
  }

  /** Host-only. Closes the room to new joins for the rest of its life. */
  private async lock(request: Request): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    const body = await request.json() as { secretHash: string };
    const found = this.findBySecret(room, body.secretHash);
    if (!found || found.peer.role !== "host") return json({ error: "Only the host may start the match." }, 401);
    room.lockedAt = room.lockedAt ?? Date.now();
    await this.ctx.storage.put("room", room);
    // Returning the roster closes a race: a guest could otherwise join between
    // the host deciding to start and the lock landing, and be left out of the
    // match config the host is about to broadcast.
    return json({
      locked_at: room.lockedAt,
      peers: Object.entries(room.peers).map(([id, peer]) => ({ peer_id: Number(id), role: peer.role })),
    });
  }

  private async leave(request: Request): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    const body = await request.json() as { secretHash: string };
    const found = this.findBySecret(room, body.secretHash);
    if (!found) return json({ error: "Invalid role secret." }, 401);
    if (found.peer.role === "host") {
      this.broadcast(this.ctx.getWebSockets(), { type: "room_closed", reason: "host_left" });
      for (const socket of this.ctx.getWebSockets()) socket.close(4003, "Host left");
      await this.ctx.storage.deleteAll();
      return new Response(null, { status: 204 });
    }
    delete room.peers[String(found.peerId)];
    await this.ctx.storage.put("room", room);
    for (const socket of this.peerSockets(found.peerId)) socket.close(4003, "Left the room");
    this.announce(found.peerId, "guest", "peer_left");
    return new Response(null, { status: 204 });
  }

  private async connectWebSocket(url: URL): Promise<Response> {
    if (url.searchParams.get("v") !== String(PROTOCOL_VERSION)) {
      return json({ error: "This game version is out of date. Please refresh the page." }, 400);
    }
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    const ticketHash = await sha256(url.searchParams.get("ticket") ?? "");
    const now = Date.now();
    let peerId = 0;
    let peer: PeerRecord | null = null;
    for (const [id, candidate] of Object.entries(room.peers)) {
      if (candidate.ticketHash === ticketHash && now <= candidate.ticketExpiresAt) {
        peerId = Number(id);
        peer = candidate;
        break;
      }
    }
    if (!peer) return json({ error: "Invalid or expired signaling ticket." }, 401);
    peer.ticketExpiresAt = 0;
    await this.ctx.storage.put("room", room);

    // A fresh ticket proves possession of the role secret, so this is the same
    // player returning after a dropped socket. Evict the stale one rather than
    // rejecting: the room may not have observed the TCP teardown yet.
    for (const existing of this.peerSockets(peerId)) {
      const previous = existing.deserializeAttachment() as SocketAttachment | null;
      existing.serializeAttachment({ ...(previous ?? { peerId, role: peer.role, connectedAt: now }), evicted: true });
      existing.close(4002, "Replaced by a reconnecting session");
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    // Tagged rather than held in a Map: the room hibernates between
    // negotiations, and an in-memory map would not survive that.
    this.ctx.acceptWebSocket(server, [peer.role, `peer:${peerId}`]);
    server.serializeAttachment({ peerId, role: peer.role, connectedAt: now } satisfies SocketAttachment);
    server.send(JSON.stringify(this.welcomeFor(room, peerId, peer.role)));
    this.announce(peerId, peer.role, "peer_joined");
    return new Response(null, { status: 101, webSocket: client });
  }

  /**
   * Tells the connecting peer who else is here. A host that reopens signalling
   * mid-lobby re-learns every guest in one message rather than inferring them,
   * and guests are told only about the host, so the room leaks nothing between
   * guests.
   */
  private welcomeFor(room: RoomRecord, peerId: number, role: Role): Record<string, unknown> {
    const peers: unknown[] = [];
    for (const [id, other] of Object.entries(room.peers)) {
      const otherId = Number(id);
      if (otherId === peerId) continue;
      if (role === "guest" && other.role !== "host") continue;
      peers.push({ peer_id: otherId, role: other.role, connected: this.peerSockets(otherId).length > 0 });
    }
    return {
      type: "welcome",
      protocol_version: PROTOCOL_VERSION,
      peer_id: peerId,
      role,
      host_peer_id: HOST_PEER_ID,
      max_peers: MAX_PEERS,
      locked: Boolean(room.lockedAt),
      peers,
    };
  }

  /** A guest's arrival or departure concerns the host; the host's concerns all. */
  private announce(peerId: number, role: Role, type: "peer_joined" | "peer_left"): void {
    const audience = role === "guest" ? this.ctx.getWebSockets("host") : this.ctx.getWebSockets("guest");
    this.broadcast(audience, { type, peer_id: peerId, role });
  }

  private peerSockets(peerId: number): WebSocket[] {
    return this.ctx.getWebSockets(`peer:${peerId}`)
      .filter((socket) => !(socket.deserializeAttachment() as SocketAttachment | null)?.evicted);
  }

  private broadcast(sockets: WebSocket[], message: unknown): void {
    const body = JSON.stringify(message);
    for (const socket of sockets) socket.send(body);
  }

  private findBySecret(room: RoomRecord, secretHash: string): { peerId: number; peer: PeerRecord } | null {
    for (const [id, peer] of Object.entries(room.peers)) {
      if (peer.secretHash === secretHash) return { peerId: Number(id), peer };
    }
    return null;
  }

  private async getLiveRoom(): Promise<RoomRecord | null> {
    const room = await this.ctx.storage.get<RoomRecord>("room");
    // A room stored under the old two-slot schema has no peers map. Treating it
    // as gone is correct: its clients are on the previous protocol version and
    // are turned away at join anyway.
    if (!room || !room.peers || Date.now() > room.hardExpiresAt) return null;
    return room;
  }
}
