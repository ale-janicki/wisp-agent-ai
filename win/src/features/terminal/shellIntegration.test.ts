import { describe, expect, it } from "vitest";
import { integrationScript, makeNonce, planLaunch, powershellScript } from "./shellIntegration";

describe("makeNonce", () => {
  it("is 128 random bits as hex, new each time", () => {
    const a = makeNonce();
    expect(a).toMatch(/^[0-9a-f]{32}$/);
    expect(makeNonce()).not.toBe(a);
  });
});

describe("the PowerShell script", () => {
  const script = powershellScript();

  it("moves the nonce out of the environment before anything else", () => {
    const lines = script.split("\n").filter((l) => l.trim() !== "" && !l.trim().startsWith("#"));
    expect(lines[0]).toContain("$env:WISP_MARK_NONCE");
    expect(script).toContain("Remove-Item Env:WISP_MARK_NONCE");
  });

  it("removes the nonce from the environment before any profile line runs, and then loads every profile", () => {
    const remove = script.indexOf("Remove-Item Env:WISP_MARK_NONCE");
    expect(remove).toBeGreaterThan(-1);
    const names = ["AllUsersAllHosts", "AllUsersCurrentHost", "CurrentUserAllHosts", "CurrentUserCurrentHost"];
    for (const name of names) expect(script.indexOf(`$PROFILE.${name}`)).toBeGreaterThan(remove);
    expect(script.indexOf(". $__wispProfile")).toBeGreaterThan(remove);
    expect(script).toMatch(/try \{ \. \$__wispProfile \} catch/);
    expect(script.indexOf("function global:prompt")).toBeGreaterThan(script.indexOf(". $__wispProfile"));
    expect(script.indexOf("Set-PSReadLineKeyHandler")).toBeGreaterThan(script.indexOf(". $__wispProfile"));
  });

  it("emits Wisp's own OSC 6973 marks A, B, C, D, cwd, hist and cmd", () => {
    for (const mark of [";A", ";B", "__wispMark 'C'", ";D;", "cwd=", "hist=", "cmd=", "declined"]) expect(script).toContain(mark);
    expect(script).toContain("]6973;");
    expect(script).not.toContain("]133;");
  });

  it("wraps the user's own prompt and Enter instead of replacing them, and touches no profile file", () => {
    expect(script).toContain("__wispOrigPrompt");
    expect(script).toContain("Set-PSReadLineKeyHandler");
    expect(script).not.toMatch(/Add-Content|Set-Content|Out-File|New-Item/);
  });

  it("does not hook twice", () => {
    expect(script).toContain("__wispHooked");
  });
});

describe("planLaunch", () => {
  it("integrates PowerShell and passes the nonce", () => {
    const plan = planLaunch("pwsh", true, "n0nce");
    expect(plan).toEqual({ shell: "pwsh", integration: integrationScript("pwsh"), nonce: "n0nce", integrated: true });
  });
  it("leaves cmd and a disabled integration plain", () => {
    expect(planLaunch("cmd", true, "n")).toEqual({ shell: "cmd", integration: null, nonce: null, integrated: false });
    expect(planLaunch("powershell", false, "n")).toEqual({ shell: "powershell", integration: null, nonce: null, integrated: false });
  });
});
