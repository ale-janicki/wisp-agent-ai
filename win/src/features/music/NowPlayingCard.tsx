import { useNowPlaying } from "./useNowPlaying";
import { clock } from "./format";
import styles from "./MusicTab.module.css";

export function NowPlayingCard() {
  const { now, artwork, press } = useNowPlaying();
  const track = now?.track;
  if (!now) return <section className={styles.now} aria-label="Tocando agora" aria-busy />;
  if (!track) {
    return (
      <section className={styles.now} aria-label="Tocando agora">
        <span className={styles.art} aria-hidden>
          ♪
        </span>
        <span className={styles.empty}>{now.empty}</span>
      </section>
    );
  }
  const fraction = track.duration > 0 ? Math.min(1, track.position / track.duration) : 0;
  return (
    <section className={styles.now} aria-label="Tocando agora">
      <span className={styles.art}>{artwork ? <img src={artwork} alt="Capa do álbum" /> : "♪"}</span>
      <div className={styles.meta}>
        <div className={styles.titleLine}>
          <span className={styles.trackTitle}>{track.title}</span>
          <span className={styles.player}>no {track.player}</span>
        </div>
        <span className={styles.artist}>{track.artist}</span>
        <div className={styles.progress} role="progressbar" aria-valuenow={Math.round(fraction * 100)} aria-valuemin={0} aria-valuemax={100}>
          <div className={styles.progressFill} style={{ width: `${Math.max(1, fraction * 100)}%` }} />
        </div>
        <div className={styles.clocks}>
          <span>{clock(track.position)}</span>
          <span>{`-${clock(Math.max(0, track.duration - track.position))}`}</span>
        </div>
      </div>
      <div className={styles.controls}>
        <button type="button" className={styles.round} onClick={() => press("previous")} title="Anterior" aria-label="Anterior">
          ⏮
        </button>
        <button
          type="button"
          className={`${styles.round} ${styles.main}`}
          onClick={() => press("playpause")}
          title={track.is_playing ? "Pausar" : "Tocar"}
          aria-label={track.is_playing ? "Pausar" : "Tocar"}
        >
          {track.is_playing ? "⏸" : "▶"}
        </button>
        <button type="button" className={styles.round} onClick={() => press("next")} title="Próxima" aria-label="Próxima">
          ⏭
        </button>
      </div>
    </section>
  );
}
