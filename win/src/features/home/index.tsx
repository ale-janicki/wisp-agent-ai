import { HomeIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "home", label: "Início", icon: HomeIcon };

export const home: Feature = {
  ...base,
  Component: comingSoon(base),
};
