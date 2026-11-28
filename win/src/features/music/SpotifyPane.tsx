import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { useFeatureEvents } from "../../shell/context";
import { TabCard } from "../../shell/TabCard";
import { MusicIcon } from "../../shell/icons";
import { copyText, useOpenExternal } from "../home/external";
import { useRichApi } from "../home/richApi";
import { count, duration } from "./format";
import type { Playlist, Results, SpotifyTrack, Status } from "./types";
import styles from "./MusicTab.module.css";

const REDIRECT_URI = "http://127.0.0.1:43821/callback";
const DASHBOARD = "https://developer.spotify.com/dashboard";
const SEARCH_DEBOUNCE = 300;
const NOTICE_OK_MS = 4000;
const NOTICE_ERROR_MS = 8000;

type Load<T> = { state: "idle" } | { state: "loading" } | { state: "loaded"; value: T } | { state: "failed"; message: string };
type Notice = { text: string; error: boolean };

const messageOf = (error: unknown, fallback: string) => (error instanceof Error && error.message ? error.message : fallback);

export function SpotifyPane() {
  const api = useRichApi("music");
  const [status, setStatus] = useState<Status | null>(null);
  const [playlists, setPlaylists] = useState<Load<Playlist[]>>({ state: "idle" });
  const [open, setOpen] = useState<Playlist | null>(null);
  const [tracks, setTracks] = useState<Load<SpotifyTrack[]>>({ state: "idle" });
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Load<Results>>({ state: "idle" });
  const [notice, setNotice] = useState<Notice | null>(null);
  const noticeTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const generation = useRef(0);

  const say = useCallback((next: Notice | null) => {
    clearTimeout(noticeTimer.current);
    setNotice(next);
    if (next) noticeTimer.current = setTimeout(() => setNotice(null), next.error ? NOTICE_ERROR_MS : NOTICE_OK_MS);
  }, []);
  useEffect(() => () => clearTimeout(noticeTimer.current), []);

  const loadStatus = useCallback(() => api.get<Status>("/status").then(setStatus).catch(() => {}), [api]);
  const loadPlaylists = useCallback(async () => {
    setPlaylists((p) => (p.state === "loaded" ? p : { state: "loading" }));
    try {
      setPlaylists({ state: "loaded", value: (await api.get<{ items: Playlist[] }>("/playlists")).items });
    } catch (error) {
      setPlaylists({ state: "failed", message: messageOf(error, "Não consegui carregar suas playlists no Spotify.") });
      void loadStatus();
    }
  }, [api, loadStatus]);

  useEffect(() => void loadStatus(), [loadStatus]);
  useFeatureEvents("music", (event) => {
    if (event.type === "auth") void loadStatus();
  });
  const signedIn = status?.signed_in === true;
  useEffect(() => {
    if (signedIn) void loadPlaylists();
  }, [signedIn, loadPlaylists]);

  useEffect(() => {
    const text = query.trim();
    const mine = ++generation.current;
    if (!signedIn || !text) return void setResults({ state: "idle" });
    const timer = setTimeout(() => {
      setResults((r) => (r.state === "loaded" ? r : { state: "loading" }));
      api
        .get<Results>("/search", { q: text })
        .then((value) => mine === generation.current && setResults({ state: "loaded", value }))
        .catch((error) => mine === generation.current && setResults({ state: "failed", message: messageOf(error, "Não consegui buscar no Spotify.") }));
    }, SEARCH_DEBOUNCE);
    return () => clearTimeout(timer);
  }, [api, query, signedIn]);

  const openPlaylist = (playlist: Playlist) => {
    setOpen(playlist);
    setTracks({ state: "loading" });
    api
      .get<{ items: SpotifyTrack[] }>(`/playlists/${encodeURIComponent(playlist.id)}/tracks`)
      .then((r) => setTracks({ state: "loaded", value: r.items }))
      .catch((error) => setTracks({ state: "failed", message: messageOf(error, "Não consegui abrir esta playlist.") }));
  };

  const run = async (request: Promise<unknown>, success?: string) => {
    say(null);
    try {
      await request;
      if (success) say({ text: success, error: false });
    } catch (error) {
      say({ text: messageOf(error, "Não consegui falar com o Spotify."), error: true });
    }
  };
  const playContext = (uri: string) => run(api.post("/play", { context_uri: uri }));
  const playTrack = (track: SpotifyTrack) => run(api.post("/play", { uris: [track.uri] }));
  const enqueue = (track: SpotifyTrack) => run(api.post("/queue", { uri: track.uri }), `“${track.name}” entra a seguir na fila.`);

  const trailing =
    signedIn && !open && !query && playlists.state === "loaded" && playlists.value.length > 0
      ? playlists.value.length === 1
        ? "1 playlist"
        : `${playlists.value.length} playlists`
      : undefined;

  return (
    <TabCard title="Spotify" icon={MusicIcon} trailing={trailing}>
      {status === null ? (
        <div className={styles.skeletonRows} aria-busy />
      ) : !signedIn ? (
        <ConnectSection status={status} reload={loadStatus} />
      ) : (
        <div className={styles.library}>
          <div className={styles.searchRow}>
            <input
              className={styles.search}
              type="search"
              placeholder="Buscar no Spotify"
              aria-label="Buscar no Spotify"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
            <button
              type="button"
              className={styles.pill}
              onClick={() => void api.post("/signout").then(() => (setOpen(null), setPlaylists({ state: "idle" }), setQuery(""), loadStatus()))}
            >
              Sair
            </button>
          </div>
          {notice && (
            <div className={notice.error ? styles.inlineError : styles.inlineOk} role={notice.error ? "alert" : "status"}>
              {notice.text}
            </div>
          )}
          {query.trim() ? (
            <SearchResults results={results} query={query.trim()} playContext={playContext} playTrack={playTrack} enqueue={enqueue} openPlaylist={openPlaylist} />
          ) : open ? (
            <PlaylistDetail playlist={open} tracks={tracks} back={() => (setOpen(null), setTracks({ state: "idle" }))} playContext={playContext} playTrack={playTrack} enqueue={enqueue} />
          ) : (
            <PlaylistGrid playlists={playlists} reload={loadPlaylists} open={openPlaylist} play={(p) => playContext(p.uri)} />
          )}
        </div>
      )}
    </TabCard>
  );
}

function ConnectSection({ status, reload }: { status: Status; reload: () => Promise<unknown> }) {
  const api = useRichApi("music");
  const [steps, setSteps] = useState(false);
  const [signing, setSigning] = useState(status.signing_in);
  useEffect(() => setSigning(status.signing_in), [status.signing_in]);

  const connect = async () => {
    if (!status.has_client_id) return setSteps((s) => !s);
    const next = await api.post<Partial<Status>>("/connect").catch(() => undefined);
    if (typeof next?.signing_in === "boolean") setSigning(next.signing_in);
    await reload();
  };
  const subtitle = signing
    ? "Termine o login no navegador; o Wisp espera até 5 minutos."
    : status.has_client_id
      ? "Suas playlists, busca e fila, tocando no seu Spotify."
      : "Antes, crie seu app no Spotify em 4 passos.";
  return (
    <div className={styles.connect}>
      <div className={styles.connectRow}>
        <button type="button" className={styles.connectButton} onClick={() => void connect()} disabled={signing}>
          <span className={styles.link} aria-hidden>
            ⛓
          </span>
          <span className={styles.connectText}>
            <span className={styles.connectTitle}>{signing ? "Conectando ao Spotify…" : "Conectar Spotify"}</span>
            <span className={styles.caption}>{subtitle}</span>
          </span>
        </button>
        {signing && (
          <button type="button" className={styles.pill} onClick={() => void api.post("/cancel").then(reload)}>
            Cancelar
          </button>
        )}
      </div>
      {status.error && (
        <div className={styles.inlineError} role="alert">
          {status.error}
        </div>
      )}
      {!status.has_client_id && steps && <SetupSteps status={status} reload={reload} />}
    </div>
  );
}

function SetupSteps({ status, reload }: { status: Status; reload: () => Promise<unknown> }) {
  const api = useRichApi("music");
  const openExternal = useOpenExternal();
  const [copied, setCopied] = useState(false);
  const [draft, setDraft] = useState(status.client_id);
  const step = (n: number, text: string, extra?: ReactNode) => (
    <div className={styles.step}>
      <span className={styles.stepNumber}>{n}</span>
      <div className={styles.stepBody}>
        <span>{text}</span>
        {extra}
      </div>
    </div>
  );
  return (
    <div className={styles.steps}>
      {step(1, "Em developer.spotify.com/dashboard, clique em Create app e dê um nome (ex.: Wisp).", (
        <button type="button" className={styles.pill} onClick={() => openExternal(DASHBOARD)}>
          Abrir painel
        </button>
      ))}
      {step(2, "Em Redirect URIs, adicione exatamente este endereço:", (
        <span className={styles.uriRow}>
          <code className={styles.uri}>{REDIRECT_URI}</code>
          <button type="button" className={styles.pill} onClick={() => void copyText(REDIRECT_URI).then(() => setCopied(true))}>
            {copied ? "Copiado" : "Copiar"}
          </button>
        </span>
      ))}
      {step(3, "Em APIs used, marque Web API e salve.")}
      {step(4, "Copie o Client ID do app e cole aqui.", (
        <span className={styles.uriRow}>
          <input className={styles.clientId} aria-label="Spotify Client ID" placeholder="cole o Client ID do seu app" value={draft} onChange={(e) => setDraft(e.target.value)} />
          <button type="button" className={styles.pill} disabled={!draft.trim()} onClick={() => void api.put("/client", { client_id: draft.trim() }).then(reload)}>
            Salvar
          </button>
        </span>
      ))}
      <p className={styles.caption}>Apps novos ficam em modo de desenvolvimento: exigem Spotify Premium do dono e liberam até 5 contas em Users Management.</p>
    </div>
  );
}

type Actions = {
  playContext: (uri: string) => void;
  playTrack: (track: SpotifyTrack) => void;
  enqueue: (track: SpotifyTrack) => void;
};

function Art({ url, round = false }: { url: string | null; round?: boolean }) {
  return <span className={`${styles.thumb} ${round ? styles.round2 : ""}`} aria-hidden>
      {url ? <img src={url} alt="" /> : "♪"}
    </span>;
}

function PlaylistGrid({ playlists, reload, open, play }: { playlists: Load<Playlist[]>; reload: () => void; open: (p: Playlist) => void; play: (p: Playlist) => void }) {
  if (playlists.state === "failed") {
    return (
      <div className={styles.column}>
        <div className={styles.inlineError} role="alert">
          {playlists.message}
        </div>
        <button type="button" className={styles.pill} onClick={reload}>
          Tentar de novo
        </button>
      </div>
    );
  }
  if (playlists.state !== "loaded") return <div className={styles.skeletonRows} aria-busy />;
  if (playlists.value.length === 0) return <p className={styles.message}>Você ainda não tem playlists no Spotify</p>;
  return (
    <div className={styles.scroll}>
      <div className={styles.caption}>Suas playlists</div>
      <div className={styles.grid}>
        {playlists.value.map((p) => (
          <div key={p.id} className={styles.tile}>
            <button type="button" className={styles.tileMain} onClick={() => open(p)} title={p.name}>
              <Art url={p.image} />
              <span className={styles.tileName}>{p.name}</span>
              <span className={styles.caption}>{count(p.track_count)}</span>
            </button>
            <button type="button" className={styles.tilePlay} onClick={() => play(p)} aria-label={`Tocar a playlist ${p.name}`} title="Tocar playlist">
              ▶
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function TrackRow({ track, actions }: { track: SpotifyTrack; actions: Actions }) {
  return (
    <li className={styles.item}>
      <Art url={track.image} />
      <span className={styles.itemText} title={`${track.name} — ${track.artists}`}>
        <span className={styles.preview}>{track.name}</span>
        <span className={styles.caption}>{track.artists}</span>
      </span>
      <span className={styles.caption}>{duration(track.duration_ms)}</span>
      <button type="button" className={styles.pill} onClick={() => actions.playTrack(track)} aria-label="Tocar">
        Tocar
      </button>
      <button type="button" className={styles.pill} onClick={() => actions.enqueue(track)} aria-label="Adicionar à fila">
        + Fila
      </button>
    </li>
  );
}

function PlaylistDetail({ playlist, tracks, back, ...actions }: { playlist: Playlist; tracks: Load<SpotifyTrack[]>; back: () => void } & Actions) {
  return (
    <div className={styles.column}>
      <div className={styles.detailHead}>
        <button type="button" className={styles.icon} onClick={back} aria-label="Voltar às playlists" title="Voltar às playlists">
          ‹
        </button>
        <Art url={playlist.image} />
        <span className={styles.itemText}>
          <span className={styles.preview}>{playlist.name}</span>
          <span className={styles.caption}>{[count(playlist.track_count), playlist.owner].filter(Boolean).join(" · ")}</span>
        </span>
        <button type="button" className={`${styles.pill} ${styles.accent}`} onClick={() => actions.playContext(playlist.uri)} aria-label="Tocar playlist">
          Tocar
        </button>
      </div>
      {tracks.state === "failed" ? (
        <p className={styles.message}>{tracks.message}</p>
      ) : tracks.state !== "loaded" ? (
        <div className={styles.skeletonRows} aria-busy />
      ) : tracks.value.length === 0 ? (
        <p className={styles.message}>Esta playlist está vazia</p>
      ) : (
        <ul className={styles.items}>
          {tracks.value.map((t) => (
            <TrackRow key={t.uri} track={t} actions={actions} />
          ))}
        </ul>
      )}
    </div>
  );
}

function SearchResults({ results, query, openPlaylist, ...actions }: { results: Load<Results>; query: string; openPlaylist: (p: Playlist) => void } & Actions) {
  if (results.state === "failed") return <p className={styles.message}>{results.message}</p>;
  if (results.state !== "loaded") return <div className={styles.skeletonRows} aria-busy />;
  const { tracks, albums, playlists, artists } = results.value;
  if (!tracks.length && !albums.length && !playlists.length && !artists.length) return <p className={styles.message}>{`Nada no Spotify para “${query}”`}</p>;
  const section = (title: string, rows: ReactNode[]) =>
    rows.length > 0 && (
      <section className={styles.section}>
        <div className={styles.caption}>{title}</div>
        <ul className={styles.items}>{rows}</ul>
      </section>
    );
  const contextRow = (key: string, image: string | null, title: string, subtitle: string, label: string, uri: string, round = false, onOpen?: () => void) => (
    <li key={key} className={styles.item}>
      <Art url={image} round={round} />
      <span className={styles.itemText} title={subtitle ? `${title} — ${subtitle}` : title}>
        {onOpen ? (
          <button type="button" className={styles.linkButton} onClick={onOpen}>
            {title}
          </button>
        ) : (
          <span className={styles.preview}>{title}</span>
        )}
        {subtitle && <span className={styles.caption}>{subtitle}</span>}
      </span>
      <button type="button" className={styles.pill} onClick={() => actions.playContext(uri)} aria-label={label}>
        {label}
      </button>
    </li>
  );
  return (
    <div className={styles.scroll}>
      {section("Músicas", tracks.map((t) => <TrackRow key={t.uri} track={t} actions={actions} />))}
      {section("Álbuns", albums.map((a) => contextRow(a.id, a.image, a.name, a.artists, "Tocar álbum", a.uri)))}
      {section("Playlists", playlists.map((p) => contextRow(p.id, p.image, p.name, count(p.track_count), "Tocar playlist", p.uri, false, () => openPlaylist(p))))}
      {section("Artistas", artists.map((a) => contextRow(a.id, a.image, a.name, "", "Tocar artista", a.uri, true)))}
    </div>
  );
}
