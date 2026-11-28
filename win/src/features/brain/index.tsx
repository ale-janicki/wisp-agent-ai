import { BrainIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "brain", label: "Brain", icon: BrainIcon };

export const brain: Feature = {
  ...base,
  Component: comingSoon(base),
};
