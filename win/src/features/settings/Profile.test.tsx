import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ProfileGroup } from "./AppearancePane";
import { NoticesPane } from "./NoticesPane";
import { baseState, renderWith, report } from "./testkit";

describe("Perfil", () => {
  it("saves name, user and avatar through setup profile and shows the CLI's sentence", async () => {
    const reload = vi.fn(async () => {});
    const view = renderWith({ "POST /api/settings/profile": () => report("profile", "done", "Perfil pronto") }, <ProfileGroup state={baseState()} reload={reload} />);
    await userEvent.clear(screen.getByLabelText("Nome do seu Wisp"));
    await userEvent.type(screen.getByLabelText("Nome do seu Wisp"), "Lia");
    await userEvent.type(screen.getByLabelText("Imagem"), "C:\\a.png");
    await userEvent.click(screen.getByRole("button", { name: "Salvar o meu Wisp" }));
    expect(await screen.findByText("Perfil pronto")).toBeInTheDocument();
    expect(view.posts("/api/settings/profile")[0]?.body).toEqual({ name: "Lia", user_name: "Bia", avatar: "C:\\a.png" });
    expect(reload).toHaveBeenCalled();
  });

  it("cannot be saved with an empty name, and Usar a padrão clears the image", async () => {
    renderWith({}, <ProfileGroup state={baseState({ profile: { name: "Wisp", user: "Bia", avatar: "C:\\a.png" } })} reload={async () => {}} />);
    await userEvent.clear(screen.getByLabelText("Como o Wisp chama você"));
    expect(screen.getByRole("button", { name: "Salvar o meu Wisp" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Usar a padrão" }));
    expect(screen.getByLabelText("Imagem")).toHaveValue("");
  });

  it("a sidecar that cannot be reached says the Mac's failure sentence", async () => {
    renderWith({}, <ProfileGroup state={baseState()} reload={async () => {}} />);
    await userEvent.click(screen.getByRole("button", { name: "Salvar o meu Wisp" }));
    expect(await screen.findByText("Não consegui salvar o perfil.")).toBeInTheDocument();
  });
});

describe("Avisos", () => {
  it("lists the Mac's seven kinds plus Não perturbe", () => {
    renderWith({}, <NoticesPane state={baseState()} reload={async () => {}} />);
    expect(screen.getAllByRole("switch").map((s) => s.getAttribute("aria-label"))).toEqual(["Não perturbe", "Respostas", "Telegram", "Lembretes", "Atualizações", "Aprovações", "Reuniões", "Convites"]);
  });

  it("a switch posts only its own key", async () => {
    const view = renderWith({ "POST /api/settings/notices": () => ({}) }, <NoticesPane state={baseState()} reload={async () => {}} />);
    await userEvent.click(screen.getByRole("switch", { name: "Reuniões" }));
    await waitFor(() => expect(view.posts("/api/settings/notices")[0]?.body).toEqual({ meeting: false }));
  });

  it("Não perturbe greys out the kinds", () => {
    renderWith({}, <NoticesPane state={baseState({ notices: { ...baseState().notices, doNotDisturb: true } })} reload={async () => {}} />);
    expect(screen.getByRole("switch", { name: "Respostas" })).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Não perturbe" })).toBeEnabled();
  });
});
