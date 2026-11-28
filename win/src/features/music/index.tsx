import { MusicIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { MusicTab } from "./MusicTab";

export const music: Feature = { id: "music", label: "Música", icon: MusicIcon, Component: MusicTab };
