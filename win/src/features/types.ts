import type { ComponentType } from "react";
import type { IconProps } from "../shell/icons";

export type Feature = {
  id: string;
  label: string;
  icon: ComponentType<IconProps>;
  Component: ComponentType;
  hasListColumn?: boolean;
  placement?: "bottom";
};
