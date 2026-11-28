import { CalendarIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "agenda", label: "Agenda", icon: CalendarIcon };

export const agenda: Feature = {
  ...base,
  Component: comingSoon(base),
};
