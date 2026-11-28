import { Divider, Group, ToggleRow } from "./ui";
import { useSettingsApi } from "./hooks";
import type { NoticeKey, SettingsState } from "./types";

const KINDS: [NoticeKey, string][] = [
  ["reply", "Respostas"], ["telegram", "Telegram"], ["reminder", "Lembretes"], ["update", "Atualizações"],
  ["approval", "Aprovações"], ["meeting", "Reuniões"], ["invite", "Convites"],
];

export function NoticesPane({ state, reload }: { state: SettingsState; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const set = async (key: NoticeKey, on: boolean) => {
    await api.post("/notices", { [key]: on });
    await reload();
  };
  const dnd = state.notices.doNotDisturb;
  return (
    <Group title="Avisos no painel" caption="O que acontece com o painel fechado aparece na pílula por alguns segundos. Clique para abrir.">
      <ToggleRow title="Não perturbe" detail="Nenhum aviso aparece enquanto estiver ligado." on={dnd} onChange={(on) => void set("doNotDisturb", on)} />
      {KINDS.map(([key, label]) => (
        <div key={key}>
          <Divider />
          <ToggleRow title={label} on={state.notices[key]} enabled={!dnd} onChange={(on) => void set(key, on)} />
        </div>
      ))}
    </Group>
  );
}
