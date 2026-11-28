import { useState } from "react";
import { Button, Detail, Divider, Group, Row, TextInput, sentence } from "./ui";
import { useAction, useSettingsApi } from "./hooks";
import type { Report, SettingsState } from "./types";

export function ProfileGroup({ state, reload }: { state: SettingsState; reload: () => Promise<void> }) {
  const api = useSettingsApi();
  const action = useAction();
  const [name, setName] = useState(state.profile.name);
  const [user, setUser] = useState(state.profile.user);
  const [avatar, setAvatar] = useState(state.profile.avatar ?? "");
  const [message, setMessage] = useState<{ text: string; failed: boolean } | null>(null);
  const canSave = !action.busy && name.trim() !== "" && user.trim() !== "";

  const save = async () => {
    setMessage(null);
    const report = await action.run(
      "profile",
      () => api.post<Report>("/profile", { name, user_name: user, ...(avatar.trim() ? { avatar: avatar.trim() } : {}) }),
      "Não consegui salvar o perfil.",
    );
    if (report) setMessage({ text: sentence(report.summary), failed: report.status === "failed" });
    else setMessage({ text: "Não consegui salvar o perfil.", failed: true });
    await reload();
  };

  return (
    <Group title="Perfil" caption="O nome do seu Wisp, como ele chama você e a imagem dele.">
      <Row title="Nome do seu Wisp">
        <TextInput aria-label="Nome do seu Wisp" placeholder="Wisp" value={name} onChange={(e) => setName(e.target.value)} />
      </Row>
      <Divider />
      <Row title="Como o Wisp chama você">
        <TextInput aria-label="Como o Wisp chama você" placeholder="seu nome" value={user} onChange={(e) => setUser(e.target.value)} />
      </Row>
      <Divider />
      <Row title="Imagem" detail="Caminho de uma imagem PNG, JPEG, GIF ou WebP de até 5 MB.">
        <TextInput aria-label="Imagem" placeholder="C:\Imagens\wisp.png" value={avatar} onChange={(e) => setAvatar(e.target.value)} />
        {avatar && <Button onClick={() => setAvatar("")}>Usar a padrão</Button>}
      </Row>
      <Divider />
      <Row title="" detail={null}>
        {message && <Detail text={message.text} />}
        <Button kind="accent" disabled={!canSave} onClick={() => void save()}>
          Salvar o meu Wisp
        </Button>
      </Row>
    </Group>
  );
}
