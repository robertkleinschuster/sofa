// An item's options that depend only on its state (pure: the sheet shows them, the unit tests read them).

import type { Item } from './types.ts';

export type DownloadAction = 'start' | 'cancel' | 'remove' | 'delete' | 'keep' | 'unkeep';

export interface Choice { label: string; run: () => void | Promise<void>; primary?: boolean; danger?: boolean; detail?: string }

// The download's options, as the TV's menu has them for its state (SFBrowseScreen+Context)
export function downloadChoices(item: Item, act: (a: DownloadAction) => void): Choice[] {
  const dl = item.dl;
  if (!dl) return [];
  switch (dl.state) {
    case 'none': return [{ label: 'Herunterladen', run: () => act('start') }];
    case 'queued': return [{ label: 'Download abbrechen', detail: 'wartet', run: () => act('cancel') }];
    case 'running': return [{ label: 'Download abbrechen', detail: `${Math.round((dl.progress ?? 0) * 100)} %`, run: () => act('cancel') }];
    case 'failed': return [
      { label: 'Erneut herunterladen', ...(dl.failure ? { detail: dl.failure } : {}), run: () => act('start') },
      { label: 'Aus Downloads entfernen', run: () => act('remove') }];
    case 'done': return [
      { label: 'Behalten', detail: dl.kept ? 'An' : 'Aus', run: () => act(dl.kept ? 'unkeep' : 'keep') },
      { label: 'Download löschen', run: () => act('delete') }];
  }
}
