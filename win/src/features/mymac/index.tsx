import { LaptopIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "mymac", label: "My Mac", icon: LaptopIcon };

export const mymac: Feature = {
  ...base,
  Component: comingSoon(base),
};
