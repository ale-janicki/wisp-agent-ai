import { bytes, celsius, duration, percent, processCpu, rate } from "./format";

describe("system formatting (SystemFormat.swift)", () => {
  it("writes bytes in decimal or binary units with a decimal comma", () => {
    expect(bytes(512)).toBe("512 B");
    expect(bytes(1_500_000)).toBe("1,5 MB");
    expect(bytes(2 * 1024 ** 3, true)).toBe("2 GB");
    expect(bytes(100_000_000_000)).toBe("100 GB");
    expect(bytes(999_960_000)).toBe("1 GB");
  });

  it("formats rates, percents, process load and temperatures", () => {
    expect(rate(250_000)).toBe("250 KB/s");
    expect(percent(0.456)).toBe("46%");
    expect(percent(Number.NaN)).toBe("0%");
    expect(percent(3)).toBe("100%");
    expect(processCpu(12.34)).toBe("12,3%");
    expect(processCpu(250)).toBe("250%");
    expect(celsius(61.6)).toBe("62 °C");
  });

  it("writes uptime the way the Mac header does", () => {
    expect(duration(45)).toBe("45 s");
    expect(duration(5 * 60)).toBe("5 min");
    expect(duration(3 * 3600 + 7 * 60)).toBe("3 h 07 min");
    expect(duration(2 * 86_400 + 5 * 3600)).toBe("2 d 5 h");
  });
});
