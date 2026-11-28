import { ClipboardIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "clipboard", label: "Copiados", icon: ClipboardIcon };

export const clipboard: Feature = {
  ...base,
  Component: comingSoon(base),
};
