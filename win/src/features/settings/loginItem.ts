import { invoke } from "@tauri-apps/api/core";
import type { LoginStatus } from "./types";

export type LoginItemApi = {
  available: boolean;
  status: () => Promise<LoginStatus>;
  set: (on: boolean) => Promise<LoginStatus>;
};

export const insideTauri = (): boolean => typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export const tauriLoginItem: LoginItemApi = {
  get available() {
    return insideTauri();
  },
  status: () => invoke<LoginStatus>("autostart_status"),
  set: (on) => invoke<LoginStatus>("autostart_set", { on }),
};

export function loginSentence(status: LoginStatus | null, error: string | null): string {
  if (error) return error;
  switch (status?.state) {
    case "enabled":
      return "O Wisp abre sozinho quando você entra no Windows.";
    case "turned_off_by_user":
      return "Desligado no Gerenciador de Tarefas. Ligue de novo para o Wisp abrir sozinho.";
    case "other_copy":
      return "Outra cópia do Wisp abre ao ligar o Windows. Ligue para trocar por esta.";
    default:
      return "O Wisp não abre sozinho ao ligar o Windows.";
  }
}
