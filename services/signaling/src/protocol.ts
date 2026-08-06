export const PROTOCOL_VERSION = 1;
export const ROOM_CODE_LENGTH = 8;
export const ROOM_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const TICKET_TTL_MS = 60_000;
export const UNJOINED_TTL_MS = 15 * 60_000;
export const ROOM_TTL_MS = 4 * 60 * 60_000;
export const TURN_TTL_SECONDS = 6 * 60 * 60;
export const MAX_SIGNAL_BYTES = 65_536;

export type Role = "host" | "guest";

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
  if (message.type === "offer" || message.type === "answer") {
    return typeof message.sdp === "string" && message.sdp.length <= MAX_SIGNAL_BYTES;
  }
  if (message.type === "ice") {
    return typeof message.media === "string" && message.media.length <= 256 &&
      Number.isInteger(message.index) &&
      typeof message.candidate === "string" && message.candidate.length <= 8_192;
  }
  return false;
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
