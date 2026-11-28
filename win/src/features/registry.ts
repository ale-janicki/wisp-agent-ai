import { home } from "./home";
import { conversa } from "./conversa";
import { brain } from "./brain";
import { tasks } from "./tasks";
import { agenda } from "./agenda";
import { meetings } from "./meetings";
import { music } from "./music";
import { clipboard } from "./clipboard";
import { terminal } from "./terminal";
import { mymac } from "./mymac";
import { settings } from "./settings";
import type { Feature } from "./types";

export const features: readonly Feature[] = [home, conversa, brain, tasks, agenda, meetings, music, clipboard, terminal, mymac, settings];

export const DEFAULT_FEATURE = "home";

export const featureById = (id: string | null | undefined): Feature | undefined => features.find((f) => f.id === id);
