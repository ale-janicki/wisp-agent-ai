import { NowPlayingCard } from "./NowPlayingCard";
import { SpotifyPane } from "./SpotifyPane";
import styles from "./MusicTab.module.css";

export function MusicTab() {
  return (
    <div className={styles.tab}>
      <NowPlayingCard />
      <SpotifyPane />
    </div>
  );
}
