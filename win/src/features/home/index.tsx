import { HomeIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { HomeTab } from "./HomeTab";

export const home: Feature = { id: "home", label: "Início", icon: HomeIcon, Component: HomeTab };
