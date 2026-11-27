import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { PermissionCard } from "./PermissionCard";

const request = {
  requestId: "r1",
  conversationId: "c1",
  toolName: "Bash",
  input: { command: "rm -rf build && echo done" },
};

describe("PermissionCard", () => {
  it("keeps Permitir disabled until the full input was expanded", async () => {
    const onAnswer = vi.fn();
    render(<PermissionCard request={request} queued={2} onAnswer={onAnswer} />);
    expect(screen.getByText("Bash")).toBeInTheDocument();
    expect(screen.getByText("+2 na fila")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Permitir" })).toBeDisabled();
    expect(screen.queryByText(/rm -rf build/)).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /veja o conteúdo inteiro/ }));
    expect(screen.getByText(/rm -rf build && echo done/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Permitir" })).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: "Permitir" }));
    expect(onAnswer).toHaveBeenCalledWith(true);
  });

  it("lets the user deny without expanding", async () => {
    const onAnswer = vi.fn();
    render(<PermissionCard request={request} queued={0} onAnswer={onAnswer} />);
    await userEvent.click(screen.getByRole("button", { name: "Negar" }));
    expect(onAnswer).toHaveBeenCalledWith(false);
  });
});
