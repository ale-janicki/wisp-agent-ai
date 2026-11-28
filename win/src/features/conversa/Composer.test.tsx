import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import type { StagedFile } from "../../api/types";
import { Composer } from "./Composer";

type HarnessProps = {
  thinking?: boolean;
  onSend?: (text: string) => void;
  onStop?: () => void;
  pending?: StagedFile[];
  onAttachFiles?: (files: File[]) => void;
  onRemove?: (path: string) => void;
  notice?: string | null;
  disabled?: boolean;
};

function Harness({ thinking = false, onSend = () => {}, onStop = () => {}, ...rest }: HarnessProps) {
  const [value, setValue] = useState("");
  return <Composer value={value} onChange={setValue} onSend={onSend} onStop={onStop} thinking={thinking} autoFocus {...rest} />;
}

const photo: StagedFile = { path: "C:\\anexos\\wisp-ab12cd34-foto.png", name: "wisp-ab12cd34-foto.png", bytes: 5, image: true };

describe("Composer", () => {
  it("Enter sends and clears; Shift+Enter inserts a newline", async () => {
    const onSend = vi.fn();
    render(<Harness onSend={onSend} />);
    const box = screen.getByPlaceholderText("Pergunte ao Wisp…");
    expect(box).toHaveFocus();
    await userEvent.type(box, "linha1{Shift>}{Enter}{/Shift}linha2");
    expect(box).toHaveValue("linha1\nlinha2");
    expect(onSend).not.toHaveBeenCalled();
    await userEvent.type(box, "{Enter}");
    expect(onSend).toHaveBeenCalledWith("linha1\nlinha2");
    expect(box).toHaveValue("");
  });

  it("queues a message while a turn runs: Parar shows beside Enviar and Enter still sends", async () => {
    const onSend = vi.fn();
    const onStop = vi.fn();
    render(<Harness thinking onSend={onSend} onStop={onStop} />);
    await userEvent.type(screen.getByPlaceholderText("Pergunte ao Wisp…"), "outra{Enter}");
    expect(onSend).toHaveBeenCalledWith("outra");
    await userEvent.click(screen.getByRole("button", { name: "Parar" }));
    expect(onStop).toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Enviar" })).toBeDisabled();
  });

  it("sends only attachments, with no text", async () => {
    const onSend = vi.fn();
    render(<Harness pending={[photo]} onSend={onSend} onRemove={() => {}} />);
    expect(screen.getByRole("button", { name: "Enviar" })).toBeEnabled();
    await userEvent.click(screen.getByRole("button", { name: "Enviar" }));
    expect(onSend).toHaveBeenCalledWith("");
  });

  it("shows pending tiles by their display name and removes one", async () => {
    const onRemove = vi.fn();
    render(<Harness pending={[photo]} onRemove={onRemove} onAttachFiles={() => {}} notice="Não anexei pasta: só dá para anexar arquivos, não pastas nem pacotes." />);
    expect(screen.getByText("foto.png")).toBeInTheDocument();
    expect(screen.getByText(/Não anexei pasta/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Remover foto.png" }));
    expect(onRemove).toHaveBeenCalledWith(photo.path);
  });

  it("attaches what the file picker chooses", async () => {
    const onAttachFiles = vi.fn();
    render(<Harness onAttachFiles={onAttachFiles} />);
    expect(screen.getByRole("button", { name: "Anexar foto ou arquivo" })).toHaveAttribute("title", "Anexar foto ou arquivo");
    const file = new File(["x"], "nota.txt", { type: "text/plain" });
    await userEvent.upload(screen.getByTestId("file-picker"), file);
    expect(onAttachFiles).toHaveBeenCalledWith([file]);
  });

  it("attaches a pasted image instead of pasting text, and lets plain text paste normally", () => {
    const onAttachFiles = vi.fn();
    render(<Harness onAttachFiles={onAttachFiles} />);
    const box = screen.getByPlaceholderText("Pergunte ao Wisp…");
    const image = new File(["png"], "image.png", { type: "image/png" });
    const pasted = fireEvent.paste(box, { clipboardData: { files: [image], getData: () => "" } });
    expect(pasted).toBe(false);
    expect(onAttachFiles).toHaveBeenCalledWith([image]);
    onAttachFiles.mockClear();
    const text = fireEvent.paste(box, { clipboardData: { files: [], getData: () => "so texto" } });
    expect(text).toBe(true);
    expect(onAttachFiles).not.toHaveBeenCalled();
  });

  it("is read only when disabled", async () => {
    const onSend = vi.fn();
    render(<Harness disabled onSend={onSend} onAttachFiles={() => {}} />);
    expect(screen.getByPlaceholderText("Pergunte ao Wisp…")).toBeDisabled();
    expect(screen.getByRole("button", { name: "Anexar foto ou arquivo" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Enviar" })).toBeDisabled();
  });
});
