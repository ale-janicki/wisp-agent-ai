import { describe, expect, it } from "vitest";
import {
  clock,
  failureLine,
  meterFraction,
  primaryAction,
  recordButton,
  shouldFollow,
  sizeText,
  statusLine,
} from "./view";
import type { Detail, Row } from "./types";

const row = (over: Partial<Row> = {}): Row => ({
  id: "a",
  title: "Plano",
  date_text: "01/05 13:30",
  duration_text: "2:05",
  badge: { label: "pronto", tone: "ready" },
  detail: null,
  notice: null,
  has_note: true,
  has_transcript: true,
  ...over,
});

const detail = (over: Partial<Detail["meta"]> = {}, rest: Partial<Detail> = {}): Detail => ({
  row: row(),
  meta: {
    status: "noted",
    failure: null,
    notice: null,
    brain_error: null,
    started_at: null,
    duration_s: 125,
    title: "Plano",
    metrics: null,
    language: "pt",
    note_state: "generated",
    sources: "both",
    webhook_sent_at: null,
    ...over,
  },
  note: "# Plano",
  lines: [],
  has_audio: true,
  brain: { label: "Salvar no brain", opens_note: false },
  job: null,
  webhook_offer: null,
  ...rest,
});

describe("clock", () => {
  it("formats m:ss and h:mm:ss like the Mac", () => {
    expect(clock(0)).toBe("0:00");
    expect(clock(65.9)).toBe("1:05");
    expect(clock(3725)).toBe("1:02:05");
    expect(clock(-3)).toBe("0:00");
  });
});

describe("statusLine", () => {
  it("is date, duration and status on one line", () => {
    expect(statusLine(row())).toBe("01/05 13:30 · 2:05 · pronto");
  });
});

describe("recordButton", () => {
  it("follows the Mac's record control", () => {
    expect(recordButton("idle", null)).toEqual({ title: "Gravar", enabled: true });
    expect(recordButton("starting", null)).toEqual({ title: "Iniciando…", enabled: false });
    expect(recordButton("recording", null)).toEqual({ title: "Parar", enabled: true });
    expect(recordButton("finishing", null)).toEqual({ title: "Salvando…", enabled: false });
    expect(recordButton("finishing", 0.426)).toEqual({ title: "Salvando 42%", enabled: false });
  });
});

describe("primaryAction", () => {
  it("is 'Gerar nota' with a transcript and no note, or after a failed run", () => {
    expect(primaryAction(detail({ status: "transcribed" }, { note: null, row: row({ has_note: false }) })).label).toBe("Gerar nota");
    expect(primaryAction(detail({ status: "failed", failure: "x" }, { note: null, row: row({ has_note: false }) })).label).toBe("Gerar nota");
  });
  it("is 'Cancelar nota' while the note is being written", () => {
    const action = primaryAction(detail({}, { job: { kind: "process", stage: "writing_note", fraction: null } }));
    expect(action).toEqual({ kind: "cancel", label: "Cancelar nota" });
  });
  it("is the brain action otherwise", () => {
    expect(primaryAction(detail())).toEqual({ kind: "saveBrain", label: "Salvar no brain" });
    expect(primaryAction(detail({}, { brain: { label: "Abrir no brain", opens_note: true } }))).toEqual({
      kind: "openBrain",
      label: "Abrir no brain",
    });
  });
  it("offers nothing while transcribing", () => {
    expect(primaryAction(detail({ status: "transcribing" }, { note: null })).kind).toBe("none");
  });
});

describe("failureLine", () => {
  it("shows the plain sentence for a note that failed and keeps the technical text for the tooltip", () => {
    expect(failureLine(detail({ failure: "nota não gerada: a IA local não está pronta" }))).toEqual({
      text: "A nota não foi gerada. Tente de novo.",
      tooltip: "nota não gerada: a IA local não está pronta",
    });
  });
  it("shows a transcription failure as it is and a brain error on its own", () => {
    expect(failureLine(detail({ status: "failed", failure: "não consegui transcrever: sem modelo" }))?.text).toBe(
      "não consegui transcrever: sem modelo",
    );
    expect(failureLine(detail({ brain_error: "sem permissão" }))?.text).toBe("sem permissão");
    expect(failureLine(detail())).toBeNull();
  });
});

describe("shouldFollow", () => {
  it("follows the end until the user scrolls up more than 24px", () => {
    expect(shouldFollow(0)).toBe(true);
    expect(shouldFollow(24)).toBe(true);
    expect(shouldFollow(25)).toBe(false);
  });
});

describe("meterFraction and sizeText", () => {
  it("meters the louder source, clamped", () => {
    expect(meterFraction({ mic: 0.2, system: 0.7 })).toBe(0.7);
    expect(meterFraction({ mic: 2, system: 0 })).toBe(1);
  });
  it("prints sizes", () => {
    expect(sizeText(483546902)).toBe("461 MB");
    expect(sizeText(3087284237)).toBe("2,9 GB");
  });
});
