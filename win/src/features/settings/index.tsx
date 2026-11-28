import { GearIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "settings", label: "Ajustes", icon: GearIcon };

export const settings: Feature = {
  ...base,
  Component: comingSoon(base),
  placement: "bottom",
};
