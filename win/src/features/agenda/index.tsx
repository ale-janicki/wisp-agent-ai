import { CalendarIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { AgendaTab } from "./AgendaTab";

export const agenda: Feature = { id: "agenda", label: "Agenda", icon: CalendarIcon, Component: () => <AgendaTab /> };
