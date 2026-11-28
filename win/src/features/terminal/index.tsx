import { TerminalIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "terminal", label: "Terminal", icon: TerminalIcon };

export const terminal: Feature = {
  ...base,
  Component: comingSoon(base),
  hasListColumn: true,
};
