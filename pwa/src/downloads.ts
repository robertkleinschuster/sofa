// Downloads from the browser (docs/pwa.md §7): the TV's own download machinery (SFDownloads - its queue,
// spacing, storage guard), asked through the item's state. What the sheet chose runs here; deleting a
// copy that can't come back (kept, or no longer online) asks first, as on the TV. The downloads on their
// way come with Sofa's status: their tiles follow (the TV's chip: "↓ 42 %"), and one that left the list
// (done, failed, cancelled on the TV) gets its final state.

import { ApiError, type Api } from './api.ts';
import { confirmSheet, type DownloadAction } from './sheet.ts';
import { updateTiles } from './tiles.ts';
import type { Item, MarkChange } from './types.ts';

export interface DownloadsHost {
  api: Api;
  toast(text: string): void;
  statusChanged(): void;   // ask Sofa's status at once (the new download's progress)
}

// what the TV says after the same choice (SFBrowseScreen+Context); a started download has Sofa's own words
const DONE_TEXT: Record<DownloadAction, string> = {
  start: 'Wird heruntergeladen – auch offline verfügbar',
  cancel: 'Download abgebrochen',
  remove: 'Aus Downloads entfernt',
  delete: 'Download gelöscht',
  keep: 'Wird behalten – nie zum Löschen vorgeschlagen',
  unkeep: 'Nicht mehr behalten',
};

const CHANGE: Record<DownloadAction, MarkChange> = {
  start: { download: true }, cancel: { download: false }, remove: { download: false }, delete: { download: false },
  keep: { keep: true }, unkeep: { keep: false },
};

export class Downloads {
  private active = new Map<string, Item>();   // id -> the item as the status listed it

  constructor(private host: DownloadsHost) {}

  act(item: Item, action: DownloadAction): void {
    const dl = item.dl;
    if (action === 'delete' && (dl?.kept || dl?.gone)) {
      confirmSheet({
        title: 'Download löschen?',
        text: dl.gone ? 'Dieses Video ist nicht mehr online – die Kopie auf dem Fernseher ist die einzige.' : 'Dieses Video ist als „Behalten“ markiert.',
        yes: 'Ja, endgültig löschen', danger: true,
        onYes: () => void this.run(item, action),
      });
      return;
    }
    void this.run(item, action);
  }

  private async run(item: Item, action: DownloadAction): Promise<void> {
    try {
      const r = await this.host.api.mark(item, CHANGE[action]);
      updateTiles(r.item);
      this.host.toast(r.message || DONE_TEXT[action]);
      if (action === 'start') this.host.statusChanged();
    } catch (e) {
      this.host.toast(e instanceof ApiError && e.unreachable ? 'Sofa ist gerade nicht erreichbar.' : e instanceof Error ? e.message : 'Das hat nicht geklappt.');
    }
  }

  // Sofa's status: the downloads queued or running now
  track(list: Item[]): void {
    const now = new Map<string, Item>();
    for (const i of list) if (i.id) now.set(i.id, i);
    for (const i of now.values()) updateTiles(i);
    for (const [id, old] of this.active) {
      if (now.has(id)) continue;
      this.host.api.mark(old, {}).then((r) => updateTiles(r.item), () => undefined);
    }
    this.active = now;
  }
}
