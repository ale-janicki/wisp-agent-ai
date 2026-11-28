import { describe, expect, it } from "vitest";
import { paletteColor } from "./palette";

describe("paletteColor", () => {
  it("uses the Mac's 16 colors, then the xterm cube and greys", () => {
    expect(paletteColor(1)).toBe("#F2555A");
    expect(paletteColor(16)).toBe("#000000");
    expect(paletteColor(196)).toBe("#ff0000");
    expect(paletteColor(231)).toBe("#ffffff");
    expect(paletteColor(232)).toBe("#080808");
    expect(paletteColor(255)).toBe("#eeeeee");
  });
});
