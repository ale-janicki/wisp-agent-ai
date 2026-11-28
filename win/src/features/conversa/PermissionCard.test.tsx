import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { PermissionCard } from "./PermissionCard";

const bash = {
  requestId: "r1",
  conversationId: "c1",
  toolName: "Bash",
  input: { command: "rm -rf build && echo done" },
  summary: "rodar rm -rf build && echo done",
  detail: "rm -rf build && echo done",
  requiresExpansion: true,
  canPersist: false,
  asker: "Claude",
};

describe("PermissionCard", () => {
  it("keeps Permitir disabled until a command that chains others was expanded", async () => {
    const onAnswer = vi.fn();
    render(<PermissionCard request={bash} queued={2} onAnswer={onAnswer} />);
    expect(screen.getByText(/O Claude quer/)).toBeInTheDocument();
    expect(screen.getByText("+2 na fila")).toBeInTheDocument();
    const allow = screen.getByRole("button", { name: "Permitir" });
    expect(allow).toBeDisabled();
    expect(allow).toHaveAttribute("title", "Abra o comando inteiro antes de permitir");
    expect(screen.queryByText("rm -rf build && echo done", { selector: "pre" })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /comando longo — veja inteiro/ }));
    expect(screen.getByText("rm -rf build && echo done", { selector: "pre" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Permitir" })).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: "Permitir" }));
    expect(onAnswer).toHaveBeenCalledWith(true);
  });

  it("does not lock a simple command the summary shows whole", async () => {
    const onAnswer = vi.fn();
    const request = { ...bash, toolName: "Bash", summary: "rodar ls", detail: "ls", requiresExpansion: false, input: { command: "ls" } };
    render(<PermissionCard request={request} queued={0} onAnswer={onAnswer} />);
    expect(screen.getByRole("button", { name: "Permitir" })).toBeEnabled();
    expect(screen.getByRole("button", { name: /detalhes/ })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Permitir" }));
    expect(onAnswer).toHaveBeenCalledWith(true);
  });

  it("fails closed: a request that does not say whether it hides something stays locked", () => {
    const { requiresExpansion: _omit, ...unknown } = bash;
    render(<PermissionCard request={unknown} queued={0} onAnswer={() => {}} />);
    expect(screen.getByRole("button", { name: "Permitir" })).toBeDisabled();
  });

  it("offers Sempre permitir only when the CLI offered a rule, and sends it as always", async () => {
    const onAnswer = vi.fn();
    const request = { ...bash, requiresExpansion: false, canPersist: true, persistRules: ["Bash(touch x *)"] };
    render(<PermissionCard request={request} queued={0} onAnswer={onAnswer} />);
    const always = screen.getByRole("button", { name: "Sempre permitir" });
    expect(always).toHaveAttribute("title", "Salva no Claude: Bash(touch x *)");
    await userEvent.click(always);
    expect(onAnswer).toHaveBeenCalledWith(true, true);
  });

  it("shows every rule Sempre permitir would save and where, as visible text", () => {
    const request = {
      ...bash,
      requiresExpansion: false,
      canPersist: true,
      persistRules: ["Bash(touch x *)", "Bash(ls *)"],
      persistWhere: ["configurações locais do projeto", "configurações do usuário (todos os projetos)"],
    };
    render(<PermissionCard request={request} queued={0} onAnswer={() => {}} />);
    expect(screen.getByText("Sempre permitir salva:")).toBeInTheDocument();
    expect(screen.getByText("Bash(touch x *)")).toBeInTheDocument();
    expect(screen.getByText(/configurações locais do projeto/)).toBeInTheDocument();
    expect(screen.getByText("Bash(ls *)")).toBeInTheDocument();
    expect(screen.getByText(/configurações do usuário/)).toBeInTheDocument();
  });

  it("shows no save line when there is nothing to persist", () => {
    render(<PermissionCard request={{ ...bash, requiresExpansion: false }} queued={0} onAnswer={() => {}} />);
    expect(screen.queryByText("Sempre permitir salva:")).not.toBeInTheDocument();
  });

  it("holds Sempre permitir behind the same expansion as Permitir", async () => {
    const request = { ...bash, canPersist: true, persistRules: ["Bash(rm *)"] };
    render(<PermissionCard request={request} queued={0} onAnswer={() => {}} />);
    expect(screen.getByRole("button", { name: "Sempre permitir" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: /comando longo/ }));
    expect(screen.getByRole("button", { name: "Sempre permitir" })).toBeEnabled();
  });

  it("names the engine that asks and uses the other tools' own lock label", () => {
    const request = { ...bash, toolName: "Write", asker: "Codex", summary: "escrever ~/a.txt", requiresExpansion: true };
    render(<PermissionCard request={request} queued={0} onAnswer={() => {}} />);
    expect(screen.getByText(/O Codex quer/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /veja o conteúdo inteiro/ })).toBeInTheDocument();
  });

  it("lets the user deny without expanding", async () => {
    const onAnswer = vi.fn();
    render(<PermissionCard request={bash} queued={0} onAnswer={onAnswer} />);
    await userEvent.click(screen.getByRole("button", { name: "Negar" }));
    expect(onAnswer).toHaveBeenCalledWith(false);
  });
});
