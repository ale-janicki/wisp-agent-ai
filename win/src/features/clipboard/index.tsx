import { ClipboardIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { ClipboardTab } from "./ClipboardTab";

export const clipboard: Feature = { id: "clipboard", label: "Copiados", icon: ClipboardIcon, Component: ClipboardTab };
