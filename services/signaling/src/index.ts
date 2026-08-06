import { DurableObject } from "cloudflare:workers";
import {
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
  type Role,
} from "./protocol";

interface Env {
  ROOMS: DurableObjectNamespace<GameRoom>;
  CREATE_RATE_LIMITER: RateLimit;
  JOIN_RATE_LIMITER: RateLimit;
  ALLOWED_ORIGINS: string;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
}

interface RoomRecord {
  createdAt: number;
  hardExpiresAt: number;
  hostSecretHash: string;
  guestSecretHash?: string;
  hostTicketHash: string;
  hostTicketExpiresAt: number;
  guestTicketHash?: string;
  guestTicketExpiresAt?: number;
}

interface SocketAttachment {
  role: Role;
  connectedAt: number;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const origin = request.headers.get("Origin");
    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }), origin, env);
    if (!isAllowedOrigin(origin, env)) return json({ error: "Origin not allowed." }, 403, origin, env);

    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, protocol_version: PROTOCOL_VERSION }, 200, origin, env);
    }
    if (request.method === "POST" && url.pathname === "/v1/rooms") {
      const limited = await env.CREATE_RATE_LIMITER.limit({ key: request.headers.get("CF-Connecting-IP") ?? "local" });
      if (!limited.success) return json({ error: "Too many rooms created. Try again shortly." }, 429, origin, env);
      const protocolError = await validateProtocolBody(request);
      if (protocolError) return json({ error: protocolError }, 400, origin, env);
      return cors(await createRoom(request, env), origin, env);
    }
    if (parts.length >= 3 && parts[0] === "v1" && parts[1] === "rooms") {
      const roomCode = normalizeRoomCode(parts[2]);
      if (!isRoomCode(roomCode)) return json({ error: "Invalid room code." }, 400, origin, env);
      const stub = env.ROOMS.get(env.ROOMS.idFromName(roomCode));
      if (request.method === "POST" && parts[3] === "join") {
        const limited = await env.JOIN_RATE_LIMITER.limit({ key: request.headers.get("CF-Connecting-IP") ?? "local" });
        if (!limited.success) return json({ error: "Too many join attempts. Try again shortly." }, 429, origin, env);
        const protocolError = await validateProtocolBody(request);
        if (protocolError) return json({ error: protocolError }, 400, origin, env);
        return cors(await joinRoom(request, env, stub, roomCode), origin, env);
      }
      if (request.method === "POST" && parts[3] === "signal-ticket") {
        return cors(await refreshTicket(request, stub), origin, env);
      }
      if (request.method === "GET" && parts[3] === "signal") {
        return stub.fetch(new Request(`https://room.internal/signal${url.search}`, request));
      }
    }
    return json({ error: "Not found." }, 404, origin, env);
  },
} satisfies ExportedHandler<Env>;

async function createRoom(request: Request, env: Env): Promise<Response> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const roomCode = randomRoomCode();
    const roleSecret = randomToken(16);
    const ticket = randomToken(18);
    const stub = env.ROOMS.get(env.ROOMS.idFromName(roomCode));
    const response = await stub.fetch("https://room.internal/create", {
      method: "POST",
      body: JSON.stringify({
        hostSecretHash: await sha256(roleSecret),
        hostTicketHash: await sha256(ticket),
      }),
    });
    if (response.status === 409) continue;
    if (!response.ok) return json({ error: "Could not create the room." }, 502);
    return roomResponse(request, env, roomCode, roleSecret, ticket, 1);
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
    body: JSON.stringify({
      guestSecretHash: await sha256(roleSecret),
      guestTicketHash: await sha256(ticket),
    }),
  });
  if (!response.ok) return new Response(response.body, { status: response.status, headers: response.headers });
  return roomResponse(request, env, roomCode, roleSecret, ticket, 2);
}

async function refreshTicket(request: Request, stub: DurableObjectStub<GameRoom>): Promise<Response> {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "Missing role secret." }, 401);
  const ticket = randomToken(18);
  return stub.fetch("https://room.internal/ticket", {
    method: "POST",
    body: JSON.stringify({
      roleSecretHash: await sha256(authorization.slice(7)),
      ticketHash: await sha256(ticket),
      ticket,
    }),
  });
}

async function roomResponse(
  request: Request,
  env: Env,
  roomCode: string,
  roleSecret: string,
  ticket: string,
  peerId: number,
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
    const body = await request.json() as { protocol_version?: number };
    return body.protocol_version === PROTOCOL_VERSION ? null : "Incompatible game version.";
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
    if (url.pathname === "/create" && request.method === "POST") return this.create(request);
    if (url.pathname === "/join" && request.method === "POST") return this.join(request);
    if (url.pathname === "/ticket" && request.method === "POST") return this.ticket(request);
    if (url.pathname === "/signal" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.connectWebSocket(url);
    }
    return json({ error: "Not found." }, 404);
  }

  async alarm(): Promise<void> {
    for (const socket of this.ctx.getWebSockets()) socket.close(4001, "Room expired");
    await this.ctx.storage.deleteAll();
  }

  async webSocketMessage(socket: WebSocket, payload: string | ArrayBuffer): Promise<void> {
    const size = typeof payload === "string" ? new TextEncoder().encode(payload).byteLength : payload.byteLength;
    if (size > MAX_SIGNAL_BYTES) {
      socket.send(JSON.stringify({ type: "error", message: "Signaling message too large." }));
      return;
    }
    try {
      const message = JSON.parse(typeof payload === "string" ? payload : new TextDecoder().decode(payload));
      if (!isSignalMessage(message)) {
        socket.send(JSON.stringify({ type: "error", message: "Invalid signaling message." }));
        return;
      }
      const attachment = socket.deserializeAttachment() as SocketAttachment;
      const other: Role = attachment.role === "host" ? "guest" : "host";
      for (const target of this.ctx.getWebSockets(other)) target.send(JSON.stringify(message));
    } catch {
      socket.send(JSON.stringify({ type: "error", message: "Invalid signaling JSON." }));
    }
  }

  async webSocketClose(socket: WebSocket, code: number, reason: string): Promise<void> {
    const attachment = socket.deserializeAttachment() as SocketAttachment | null;
    if (attachment) {
      const other: Role = attachment.role === "host" ? "guest" : "host";
      for (const target of this.ctx.getWebSockets(other)) target.send(JSON.stringify({ type: "peer_left" }));
    }
    socket.close(code, reason);
  }

  private async create(request: Request): Promise<Response> {
    if (await this.ctx.storage.get<RoomRecord>("room")) return json({ error: "Room already exists." }, 409);
    const body = await request.json() as Pick<RoomRecord, "hostSecretHash" | "hostTicketHash">;
    const now = Date.now();
    const room: RoomRecord = {
      createdAt: now,
      hardExpiresAt: now + ROOM_TTL_MS,
      hostSecretHash: body.hostSecretHash,
      hostTicketHash: body.hostTicketHash,
      hostTicketExpiresAt: now + TICKET_TTL_MS,
    };
    await this.ctx.storage.put("room", room);
    await this.ctx.storage.setAlarm(room.hardExpiresAt);
    return json({ ok: true }, 201);
  }

  private async join(request: Request): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    if (!room.guestSecretHash && Date.now() - room.createdAt > UNJOINED_TTL_MS) {
      return json({ error: "Room expired before a friend joined." }, 410);
    }
    if (room.guestSecretHash) return json({ error: "Room is full." }, 409);
    const body = await request.json() as { guestSecretHash: string; guestTicketHash: string };
    room.guestSecretHash = body.guestSecretHash;
    room.guestTicketHash = body.guestTicketHash;
    room.guestTicketExpiresAt = Date.now() + TICKET_TTL_MS;
    await this.ctx.storage.put("room", room);
    return json({ ok: true });
  }

  private async ticket(request: Request): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    const body = await request.json() as { roleSecretHash: string; ticketHash: string; ticket: string };
    const now = Date.now();
    if (body.roleSecretHash === room.hostSecretHash) {
      room.hostTicketHash = body.ticketHash;
      room.hostTicketExpiresAt = now + TICKET_TTL_MS;
    } else if (body.roleSecretHash === room.guestSecretHash) {
      room.guestTicketHash = body.ticketHash;
      room.guestTicketExpiresAt = now + TICKET_TTL_MS;
    } else {
      return json({ error: "Invalid role secret." }, 401);
    }
    await this.ctx.storage.put("room", room);
    return json({ signal_ticket: body.ticket });
  }

  private async connectWebSocket(url: URL): Promise<Response> {
    const room = await this.getLiveRoom();
    if (!room) return json({ error: "Room not found or expired." }, 410);
    const ticketHash = await sha256(url.searchParams.get("ticket") ?? "");
    const now = Date.now();
    let role: Role | null = null;
    if (ticketHash === room.hostTicketHash && now <= room.hostTicketExpiresAt) role = "host";
    if (ticketHash === room.guestTicketHash && now <= (room.guestTicketExpiresAt ?? 0)) role = "guest";
    if (!role) return json({ error: "Invalid or expired signaling ticket." }, 401);
    if (this.ctx.getWebSockets(role).length > 0) return json({ error: "Role is already connected." }, 409);
    if (role === "host") room.hostTicketExpiresAt = 0;
    else room.guestTicketExpiresAt = 0;
    await this.ctx.storage.put("room", room);

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role, connectedAt: now } satisfies SocketAttachment);
    if (this.ctx.getWebSockets("host").length && this.ctx.getWebSockets("guest").length) {
      const joined = JSON.stringify({ type: "peer_joined" });
      for (const socket of this.ctx.getWebSockets()) socket.send(joined);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private async getLiveRoom(): Promise<RoomRecord | null> {
    const room = await this.ctx.storage.get<RoomRecord>("room");
    if (!room || Date.now() > room.hardExpiresAt) return null;
    return room;
  }
}
