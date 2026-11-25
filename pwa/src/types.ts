// The JSON Sofa answers (src/Library/SFWebItems.m, src/Shell/SFWebServer+API.m; docs/pwa.md).

export type TileStyle = 'landscape' | 'circle' | 'poster' | 'app' | 'wide' | 'button';

export interface Broadcast { title: string; subtitle?: string; plot?: string; start: number; end: number }

export interface Item {
  kind: 'video' | 'live' | 'folder' | 'action';
  id?: string;
  title?: string;
  sub?: string;
  plot?: string;
  channel?: string;
  source?: string;
  station?: string;      // the broadcaster: its mark (res/logos/marks) is the tile's avatar
  theme?: string;
  badge?: string;
  drm?: boolean;
  duration?: number;
  date?: number;
  logo?: string;
  logoVariant?: number;
  tint?: string;
  fit?: boolean;
  heroTitle?: string;
  heroMeta?: string;
  showRef?: string;
  style?: TileStyle;
  mark?: boolean;
  img?: string;
  imgFallback?: string;
  backdrop?: string;
  channelImg?: string;
  progress?: number;
  watched?: boolean;
  later?: boolean;
  following?: boolean;
  chip?: string;
  now?: Broadcast;
  next?: Broadcast;
  page?: string;          // handle of the folder's page
  open?: 'app' | 'search';
  arg?: string;
  d?: Record<string, unknown>;   // the stored dictionary, echoed back to play or mark
}

export interface Shelf {
  title?: string;
  layout: 'rail' | 'grid';
  style: TileStyle;
  items: Item[];
  more?: string;
  focus?: number;
}

export interface Page {
  title?: string;
  subtitle?: string;
  theme?: string;
  backdrop?: string;
  empty?: string;
  shelves: Shelf[];
}

export interface Theme {
  background?: string; backgroundTop?: string; surface?: string; text?: string; textDim?: string;
  accent?: string; accentText?: string; focus?: string; focusText?: string; progress?: string;
  seekBar?: string; wordmarkColor?: string; headerMarkColor?: string;
  fonts: { regular: string; medium: string; bold: string; wordmark: string };
  corner: number;
  light: boolean;
  uppercaseHeaders: boolean;
  wordmark?: string;
  logo?: string;
  logoVariant?: number;
  headerMark: 'none' | 'playPill' | 'bar' | 'dot';
}

export interface AppInfo { id: string; name: string; summary: string; search: boolean; searchPlaceholder?: string }

export interface Info { apps: AppInfo[]; themes: Record<string, Theme>; device: string; host: string }

export interface MoreAnswer { items: Item[]; more: boolean }

export interface SearchRecent { recent: string[] }

export interface PlayAnswer { stream: string; kind: 'hls' | 'file'; url: string; start: number; duration: number; live: boolean; title: string }
