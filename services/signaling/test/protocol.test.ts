import { describe, expect, it } from "vitest";
import { isRoomCode, isSignalMessage, normalizeRoomCode, randomRoomCode } from "../src/protocol";

describe("room protocol", () => {
  it("normalizes human-entered codes", () => {
    expect(normalizeRoomCode(" abcd-1234 ")).toBe("ABCD1234");
  });

  it("creates valid unambiguous codes", () => {
    for (let index = 0; index < 100; index++) expect(isRoomCode(randomRoomCode())).toBe(true);
  });

  it("rejects ambiguous and malformed codes", () => {
    expect(isRoomCode("O0IL1234")).toBe(false);
    expect(isRoomCode("TOO-SHORT")).toBe(false);
  });

  it("accepts only bounded WebRTC signaling messages", () => {
    expect(isSignalMessage({ type: "offer", sdp: "v=0" })).toBe(true);
    expect(isSignalMessage({ type: "ice", media: "0", index: 0, candidate: "candidate" })).toBe(true);
    expect(isSignalMessage({ type: "score", value: 999 })).toBe(false);
  });
});
