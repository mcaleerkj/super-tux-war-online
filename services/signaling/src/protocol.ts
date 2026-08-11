// Must stay in lockstep with NetworkProtocol.VERSION in
// scripts/network/network_protocol.gd — the Worker rejects any other value.
export const PROTOCOL_VERSION = 2;
export const ROOM_CODE_LENGTH = 8;
export const ROOM_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const TICKET_TTL_MS = 60_000;
export const UNJOINED_TTL_MS = 15 * 60_000;
export const ROOM_TTL_MS = 4 * 60 * 60_000;
export const TURN_TTL_SECONDS = 6 * 60 * 60;
export const MAX_SIGNAL_BYTES = 65_536;

export const HOST_PEER_ID = 1;
/** 1 host + 5 guests. Must match NetworkProtocol.MAX_PLAYERS. */
export const MAX_PEERS = 6;
/**
 * Peer ids are handed out monotonically and never reused, so a guest that
 * leaves and is replaced can never be aliased onto the departed peer's
 * half-negotiated connection or stale roster entry. Capacity is enforced by
 * counting live peers, so leaving still frees a seat; this is only the ceiling
 * on churn before the room is considered spent.
 */
export const MAX_PEER_ID = 64;

export type Role = "host" | "guest";

export interface PeerRecord {
  role: Role;
  secretHash: string;
  ticketHash: string;
  ticketExpiresAt: number;
  joinedAt: number;
}

export interface RoomRecord {
  createdAt: number;
  hardExpiresAt: number;
  /** Set when the host starts the match. Once set, joining is refused forever. */
  lockedAt?: number;
  nextPeerId: number;
  peers: Record<string, PeerRecord>;
}

export interface SocketAttachment {
  peerId: number;
  role: Role;
  connectedAt: number;
  /** Set when the same peer reconnected and took over this slot. */
  evicted?: boolean;
}

export function isPeerId(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= HOST_PEER_ID && (value as number) <= MAX_PEER_ID;
}

export function normalizeRoomCode(value: string): string {
  return value.trim().toUpperCase().replace(/[\s-]/g, "");
}

export function isRoomCode(value: string): boolean {
  const normalized = normalizeRoomCode(value);
  return normalized.length === ROOM_CODE_LENGTH &&
    [...normalized].every((character) => ROOM_ALPHABET.includes(character));
}

export function randomToken(bytes = 16): string {
  const value = crypto.getRandomValues(new Uint8Array(bytes));
  return toBase64Url(value);
}

export function randomRoomCode(): string {
  const value = crypto.getRandomValues(new Uint8Array(ROOM_CODE_LENGTH));
  return [...value].map((byte) => ROOM_ALPHABET[byte % ROOM_ALPHABET.length]).join("");
}

export async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return toBase64Url(new Uint8Array(digest));
}

export function isSignalMessage(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object") return false;
  const message = value as Record<string, unknown>;
  // With more than two peers the relay can no longer infer the target, so `to`
  // is mandatory. `from` is stamped by the room from the socket's own identity;
  // rejecting a client-supplied one rather than stripping it turns a spoofing
  // attempt into a visible error instead of silently accepting the message.
  if (!isPeerId(message.to)) return false;
  if ("from" in message) return false;
  if (message.type === "offer" || message.type === "answer") {
    return typeof message.sdp === "string" && message.sdp.length > 0 &&
      message.sdp.length <= MAX_SIGNAL_BYTES;
  }
  if (message.type === "ice") {
    return typeof message.media === "string" && message.media.length <= 256 &&
      Number.isInteger(message.index) && (message.index as number) >= 0 && (message.index as number) < 256 &&
      typeof message.candidate === "string" && message.candidate.length <= 8_192;
  }
  return false;
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
