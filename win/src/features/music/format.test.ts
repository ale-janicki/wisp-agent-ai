import { clock, count, duration } from "./format";

describe("Spotify formatting (SpotifyFormat.swift)", () => {
  it("writes track length as m:ss", () => {
    expect(duration(205_000)).toBe("3:25");
    expect(duration(-5)).toBe("0:00");
    expect(duration(61_000)).toBe("1:01");
  });
  it("counts tracks the Mac's way", () => {
    expect(count(null)).toBe("Playlist");
    expect(count(1)).toBe("1 música");
    expect(count(12)).toBe("12 músicas");
  });
  it("writes playback position as m:ss from seconds", () => {
    expect(clock(12.9)).toBe("0:12");
    expect(clock(3 * 60 + 8)).toBe("3:08");
  });
});
