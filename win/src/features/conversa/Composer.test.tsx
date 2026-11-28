import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { Composer } from "./Composer";

function Harness({ thinking = false, onSend = () => {}, onStop = () => {} }) {
  const [value, setValue] = useState("");
  return <Composer value={value} onChange={setValue} onSend={onSend} onStop={onStop} thinking={thinking} autoFocus />;
}

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

  it("shows Parar while thinking and does not send", async () => {
    const onSend = vi.fn();
    const onStop = vi.fn();
    render(<Harness thinking onSend={onSend} onStop={onStop} />);
    await userEvent.type(screen.getByPlaceholderText("Pergunte ao Wisp…"), "oi{Enter}");
    expect(onSend).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole("button", { name: "Parar" }));
    expect(onStop).toHaveBeenCalled();
  });
});
