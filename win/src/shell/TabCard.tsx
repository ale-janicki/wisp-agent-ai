import type { ComponentType, ReactNode } from "react";
import type { IconProps } from "./icons";
import styles from "./TabCard.module.css";

type CardProps = {
  title: string;
  icon: ComponentType<IconProps>;
  trailing?: string;
  children: ReactNode;
};

export function TabCard({ title, icon: Icon, trailing, children }: CardProps) {
  return (
    <section className={styles.card} aria-label={title}>
      <header className={styles.head}>
        <span className={styles.icon}>
          <Icon size={14} />
        </span>
        <h2 className={styles.title}>{title}</h2>
        {trailing && <span className={styles.trailing}>{trailing}</span>}
      </header>
      <div className={styles.body}>{children}</div>
    </section>
  );
}

export function TabMessage({ text }: { text: string }) {
  return <p className={styles.message}>{text}</p>;
}
