import { TerminalIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { TerminalTab } from "./TerminalTab";

export const terminal: Feature = {
  id: "terminal",
  label: "Terminal",
  icon: TerminalIcon,
  Component: TerminalTab,
  hasListColumn: true,
};
