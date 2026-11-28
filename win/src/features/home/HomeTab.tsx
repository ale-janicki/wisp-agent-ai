import { useEffect, useState, type ReactNode } from "react";
import { useRichApi } from "./richApi";
import { useShell } from "../../shell/context";
import { ChatIcon, MusicIcon } from "../../shell/icons";
import { Composer } from "../conversa/Composer";
import { clock } from "../music/format";
import { useNowPlaying } from "../music/useNowPlaying";
import { age, clockTime, conversationDate, dayTime, tokens } from "./format";
import type { ConversationItem, LimitRow, Profile, Usage } from "./types";
import styles from "./HomeTab.module.css";

const USAGE_POLL_MS = 15_000;

export function HomeTab() {
  const api = useRichApi("home");
  const { session, draft, setDraft, focusComposer, navigate } = useShell();
  const [profile, setProfile] = useState<Profile | null>(null);
  useEffect(() => {
    let alive = true;
    api
      .get<Profile>("/profile")
      .then((p) => alive && setProfile(p))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [api]);

  const chat = session.state;
  const thinking = chat.currentId !== null && chat.status[chat.currentId] === "thinking";
  const first = profile?.first_name;

  return (
    <div className={styles.home}>
      <h2 className={styles.greeting}>{first ? `Olá, ${first}!` : "Olá!"}</h2>
      <p className={styles.sub}>{`Escreva para o ${profile?.persona ?? "Wisp"}`}</p>
      <div className={styles.composer}>
        <Composer
          value={draft}
          onChange={setDraft}
          onSend={(text) => {
            void session.send(text);
            navigate("conversa");
          }}
          onStop={() => void session.stop()}
          thinking={thinking}
          autoFocus={focusComposer}
        />
      </div>
      <div className={styles.tiles}>
        <MusicTile />
        <UsageTile />
        <ConversationsTile />
      </div>
    </div>
  );
}

function Tile({ title, trailing, icon, children }: { title: string; trailing?: string | null; icon: ReactNode; children: ReactNode }) {
  return (
    <section className={styles.tile} aria-label={title}>
      <header className={styles.tileHead}>
        <span className={styles.tileIcon}>{icon}</span>
        <h3 className={styles.tileTitle}>{title}</h3>
        {trailing && <span className={styles.trailing}>{trailing}</span>}
      </header>
      {children}
    </section>
  );
}

function MusicTile() {
  const { now, artwork, press } = useNowPlaying();
  const track = now?.track ?? null;
  const fraction = track && track.duration > 0 ? Math.min(1, track.position / track.duration) : 0;
  return (
    <Tile title="Música" trailing={track?.player} icon={<MusicIcon size={12} />}>
      {track ? (
        <div className={styles.music}>
          <div className={styles.musicTop}>
            <span className={styles.art}>{artwork ? <img src={artwork} alt="Capa do álbum" /> : <span aria-hidden>♪</span>}</span>
            <div className={styles.musicText}>
              <span className={styles.trackTitle}>{track.title}</span>
              <span className={styles.caption}>{track.artist}</span>
              <div className={styles.progress}>
                <div className={styles.progressFill} style={{ width: `${Math.max(1, fraction * 100)}%` }} />
              </div>
              <div className={styles.clocks}>
                <span>{clock(track.position)}</span>
                <span>{`-${clock(Math.max(0, track.duration - track.position))}`}</span>
              </div>
            </div>
          </div>
          <div className={styles.controls}>
            <button type="button" className={styles.round} onClick={() => press("previous")} aria-label="Anterior" title="Anterior">
              ⏮
            </button>
            <button type="button" className={`${styles.round} ${styles.main}`} onClick={() => press("playpause")} aria-label={track.is_playing ? "Pausar" : "Tocar"} title={track.is_playing ? "Pausar" : "Tocar"}>
              {track.is_playing ? "⏸" : "▶"}
            </button>
            <button type="button" className={styles.round} onClick={() => press("next")} aria-label="Próxima" title="Próxima">
              ⏭
            </button>
          </div>
        </div>
      ) : (
        <p className={styles.message}>{now?.empty ?? ""}</p>
      )}
    </Tile>
  );
}

function UsageTile() {
  const api = useRichApi("home");
  const [usage, setUsage] = useState<Usage | null>(null);
  useEffect(() => {
    let alive = true;
    const load = () =>
      api
        .get<Usage>("/usage")
        .then((u) => alive && setUsage(u))
        .catch(() => {});
    void load();
    const timer = setInterval(() => void load(), USAGE_POLL_MS);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [api]);

  const limits = usage?.limits ?? null;
  return (
    <Tile title="Uso do Claude" trailing={limits ? age(limits.captured_at) : null} icon={<span aria-hidden>▮</span>}>
      <div className={styles.usage}>
        {limits ? limits.rows.map((row) => <LimitBar key={row.kind} row={row} />) : usage && <p className={styles.caption}>Abra o Claude Code para ler o limite</p>}
        {usage?.tokens && <p className={styles.tokens}>{`Hoje ${tokens(usage.tokens.today)} tokens · 7 dias ${tokens(usage.tokens.week)} tokens`}</p>}
      </div>
    </Tile>
  );
}

function LimitBar({ row }: { row: LimitRow }) {
  const name = row.kind === "session" ? "Sessão" : "Semana";
  if (row.state === "renewed") {
    return (
      <div className={styles.limit}>
        <span className={styles.limitLabel}>{`${name} renovado`}</span>
        <div className={styles.track} role="progressbar" aria-label={name} aria-valuenow={0} aria-valuemin={0} aria-valuemax={100} />
      </div>
    );
  }
  const reset = row.resets_at === null ? null : new Date(row.resets_at * 1000);
  const detail = reset ? `· renova ${row.kind === "session" ? clockTime(reset) : dayTime(reset)}` : null;
  const percent = Math.min(100, Math.max(0, row.percent));
  return (
    <div className={styles.limit}>
      <div className={styles.limitHead}>
        <span className={styles.limitLabel}>{`${name} ${row.percent}%`}</span>
        {detail && <span className={styles.caption}>{detail}</span>}
      </div>
      <div className={styles.track} role="progressbar" aria-label={name} aria-valuenow={percent} aria-valuemin={0} aria-valuemax={100}>
        <div className={`${styles.fill} ${styles[row.severity]}`} style={{ width: `${percent}%` }} />
      </div>
    </div>
  );
}

function ConversationsTile() {
  const api = useRichApi("home");
  const { session, navigate } = useShell();
  const [data, setData] = useState<{ items: ConversationItem[]; total: number } | null>(null);
  useEffect(() => {
    let alive = true;
    api
      .get<{ items: ConversationItem[]; total: number }>("/conversations")
      .then((d) => alive && setData(d))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [api]);

  return (
    <Tile title="Conversas" trailing={data && data.total > 0 ? String(data.total) : null} icon={<ChatIcon size={12} />}>
      {data && data.items.length === 0 ? (
        <p className={styles.message}>Nenhuma conversa ainda</p>
      ) : (
        <ul className={styles.rows}>
          {data?.items.map((item) => (
            <li key={item.id}>
              <button
                type="button"
                className={styles.row}
                title={item.title}
                onClick={() => {
                  void session.open(item.id);
                  navigate("conversa");
                }}
              >
                <span className={styles.avatar} aria-hidden>
                  {item.telegram ? "➤" : "◉"}
                </span>
                <span className={styles.rowText}>
                  <span className={styles.rowHead}>
                    <span className={styles.rowTitle}>{item.title}</span>
                    <span className={styles.caption}>{conversationDate(new Date(item.updated_at))}</span>
                  </span>
                  {item.preview && <span className={styles.caption}>{item.preview}</span>}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </Tile>
  );
}
