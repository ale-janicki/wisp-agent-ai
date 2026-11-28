import { MusicIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "music", label: "Música", icon: MusicIcon };

export const music: Feature = {
  ...base,
  Component: comingSoon(base),
};
