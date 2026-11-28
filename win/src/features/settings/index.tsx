import { GearIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { SettingsTab } from "./SettingsTab";

export const settings: Feature = {
  id: "settings",
  label: "Ajustes",
  icon: GearIcon,
  Component: () => <SettingsTab />,
  placement: "bottom",
};
