import { ChatIcon } from "../../shell/icons";
import type { Feature } from "../types";
import { ConversaTab } from "./ConversaTab";

export const conversa: Feature = {
  id: "conversa",
  label: "Conversa",
  icon: ChatIcon,
  Component: ConversaTab,
  hasListColumn: true,
};
