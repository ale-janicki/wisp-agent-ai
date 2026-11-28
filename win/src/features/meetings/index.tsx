import { WaveformIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { MeetingsTab } from "./MeetingsTab";

export const meetings: Feature = {
  id: "meetings",
  label: "Reuniões",
  icon: WaveformIcon,
  Component: MeetingsTab,
  hasListColumn: true,
};
