// What a page looks like while Sofa loads it: its shape in the page's colours - shelves of tiles of
// the real sizes (the same classes), shimmering softly - so the content takes their places instead
// of pushing a spinner away. Announced as busy to screen readers.

import { h } from './dom.ts';
import type { TileStyle } from './types.ts';

function skeletonTile(style: TileStyle): HTMLElement {
  return h('div.tile.skeleton-tile', { dataset: { style } },
    h('div.art.skeleton-block'),
    h('div.meta', null, h('div.skeleton-line'), h('div.skeleton-line.short')));
}

function skeletonShelf(style: TileStyle, count: number): HTMLElement {
  return h('section.shelf', { dataset: { layout: 'rail', style } },
    h('div.shelf-title.skeleton-line.title'),
    h('div.tiles', null, ...Array.from({ length: count }, () => skeletonTile(style))));
}

export function skeletonPage(opts: { showTitle: boolean }): HTMLElement {
  return h('div.page.skeleton', { 'aria-busy': 'true', 'aria-label': 'Lädt' },
    opts.showTitle ? h('header.page-head', null, h('div.skeleton-line.heading')) : null,
    skeletonShelf('landscape', 5), skeletonShelf('landscape', 5), skeletonShelf('landscape', 5));
}
