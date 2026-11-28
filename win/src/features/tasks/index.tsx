import { TasksIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { TasksTab } from "./TasksTab";

export const tasks: Feature = { id: "tasks", label: "Tarefas", icon: TasksIcon, Component: TasksTab };
