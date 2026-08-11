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

  it("accepts only bounded, addressed WebRTC signaling messages", () => {
    expect(isSignalMessage({ type: "offer", to: 2, sdp: "v=0" })).toBe(true);
    expect(isSignalMessage({ type: "ice", to: 1, media: "0", index: 0, candidate: "candidate" })).toBe(true);
    expect(isSignalMessage({ type: "score", to: 1, value: 999 })).toBe(false);
  });

  it("requires an address now that more than one peer can receive", () => {
    expect(isSignalMessage({ type: "offer", sdp: "v=0" })).toBe(false);
    expect(isSignalMessage({ type: "offer", to: 0, sdp: "v=0" })).toBe(false);
    expect(isSignalMessage({ type: "offer", to: 999, sdp: "v=0" })).toBe(false);
    expect(isSignalMessage({ type: "offer", to: "2", sdp: "v=0" })).toBe(false);
  });

  it("rejects a client that names its own sender", () => {
    // The room stamps `from` from the socket's identity. A message carrying one
    // is an impersonation attempt and must fail loudly rather than be sanitised.
    expect(isSignalMessage({ type: "offer", to: 2, from: 1, sdp: "v=0" })).toBe(false);
    expect(isSignalMessage({ type: "ice", to: 1, from: 3, media: "0", index: 0, candidate: "c" })).toBe(false);
  });

  it("bounds the ICE payload", () => {
    expect(isSignalMessage({ type: "offer", to: 2, sdp: "" })).toBe(false);
    expect(isSignalMessage({ type: "ice", to: 1, media: "0", index: -1, candidate: "c" })).toBe(false);
    expect(isSignalMessage({ type: "ice", to: 1, media: "0", index: 999, candidate: "c" })).toBe(false);
    expect(isSignalMessage({ type: "ice", to: 1, media: "x".repeat(300), index: 0, candidate: "c" })).toBe(false);
  });
});
