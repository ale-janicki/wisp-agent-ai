import { TasksIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "tasks", label: "Tarefas", icon: TasksIcon };

export const tasks: Feature = {
  ...base,
  Component: comingSoon(base),
};
