export type Status = {
  storage: boolean;
  has_client_id: boolean;
  client_id: string;
  signed_in: boolean;
  signing_in: boolean;
  error: string | null;
  media: boolean;
};

export type Track = { player: string; title: string; artist: string; album: string; is_playing: boolean; position: number; duration: number; key: string };
export type Now = { track: Track | null; empty: string };

export type Playlist = { id: string; name: string; uri: string; image: string | null; owner: string | null; track_count: number | null; collaborative: boolean };
export type SpotifyTrack = { uri: string; name: string; artists: string; duration_ms: number; image: string | null };
export type Album = { id: string; name: string; uri: string; image: string | null; artists: string; total_tracks: number | null };
export type Artist = { id: string; name: string; uri: string; image: string | null };
export type Results = { tracks: SpotifyTrack[]; albums: Album[]; playlists: Playlist[]; artists: Artist[] };
