import type { ReactNode } from "react";

export type IconProps = { size?: number };

function icon(name: string, paths: ReactNode) {
  const Icon = ({ size = 16 }: IconProps) => (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
      focusable="false"
    >
      {paths}
    </svg>
  );
  Icon.displayName = name;
  return Icon;
}

export const HomeIcon = icon("HomeIcon", <path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z" />);
export const ChatIcon = icon("ChatIcon", <path d="M4 5h11v8H8l-4 3zM15 9h5v8l-3-2h-5v-2" />);
export const BrainIcon = icon(
  "BrainIcon",
  <path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 3 5 3 3 0 0 0 5 1V5a2 2 0 0 0-3-1zM15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-3 5 3 3 0 0 1-5 1" />,
);
export const TasksIcon = icon("TasksIcon", <path d="M4 6l2 2 3-3M4 14l2 2 3-3M12 7h8M12 15h8" />);
export const CalendarIcon = icon("CalendarIcon", <path d="M4 6h16v14H4zM4 10h16M8 3v4M16 3v4" />);
export const WaveformIcon = icon("WaveformIcon", <path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4" />);
export const MusicIcon = icon("MusicIcon", <path d="M9 18V6l10-2v12M9 18a3 3 0 1 1-3-3 3 3 0 0 1 3 3zM19 16a3 3 0 1 1-3-3 3 3 0 0 1 3 3z" />);
export const ClipboardIcon = icon("ClipboardIcon", <path d="M8 5h8v3H8zM6 6H5v15h14V6h-1M9 13h6M9 17h6" />);
export const TerminalIcon = icon("TerminalIcon", <path d="M4 5h16v14H4zM7 10l3 2-3 2M12 15h5" />);
export const LaptopIcon = icon("LaptopIcon", <path d="M5 5h14v10H5zM2 19h20" />);
export const GearIcon = icon(
  "GearIcon",
  <path d="M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1" />,
);
export const WindowIcon = icon("WindowIcon", <path d="M3 5h18v14H3zM3 9h18" />);
