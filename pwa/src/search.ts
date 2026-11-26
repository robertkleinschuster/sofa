// An app's search (the TV's keyboard screen): suggestions while typing, the household's recent
// searches (shared with the TV), results as the app's search page.

import type { Api } from './api.ts';
import { clear, h } from './dom.ts';
import { renderPage } from './pages.ts';
import { skeletonPage } from './skeleton.ts';
import type { TileHost } from './tiles.ts';
import type { AppInfo } from './types.ts';

export function searchScreen(api: Api, app: AppInfo, query: string | undefined, host: TileHost,
  submit: (q: string) => void): HTMLElement {
  const input = h('input.field.search-field', {
    type: 'search', enterkeyhint: 'search', autocomplete: 'off', value: query ?? '',
    placeholder: app.searchPlaceholder ?? `${app.name} durchsuchen`, 'aria-label': `${app.name} durchsuchen`,
  });
  const hints = h('div.search-hints');
  const results = h('div.search-results');
  const form = h('form.search-form', {
    onsubmit: (e: Event) => { e.preventDefault(); const q = input.value.trim(); if (q) { input.blur(); submit(q); } },
  }, input);

  const chips = (title: string, list: string[]): void => {
    clear(hints);
    if (!list.length) return;
    hints.append(h('h2.shelf-title', null, title),
      h('div.chips', null, ...list.slice(0, 12).map((q) => h('button.chip-button', { type: 'button', onclick: () => submit(q) }, q))));
  };

  let typed = 0;
  input.addEventListener('input', () => {
    const q = input.value.trim(), mine = ++typed;
    if (!q) { void showRecent(); return; }
    setTimeout(() => {
      if (mine !== typed) return;
      api.suggest(app.id, q).then((r) => { if (mine === typed) chips('Vorschläge', r.list.filter((s) => typeof s === 'string')); }).catch(() => undefined);
    }, 250);
  });
  const showRecent = async (): Promise<void> => {
    let recent: string[] = [];
    try { recent = (await api.recentSearches(app.id)).recent; } catch { /* none */ }
    if (input.value.trim()) return;
    if (recent.length) chips('Zuletzt gesucht', recent);
    else { clear(hints); hints.append(h('p.search-hint', null, `Was möchtest du in ${app.name} finden? Vorschläge erscheinen beim Tippen.`)); }
  };

  if (query) {
    results.append(skeletonPage({ showTitle: false }));
    api.search(app.id, query).then((page) => {
      clear(results);
      results.append(renderPage(page, host, { showTitle: false }));
    }).catch((e: unknown) => {
      clear(results);
      results.append(h('p.empty', null, e instanceof Error ? e.message : 'Die Suche hat nicht geklappt.'));
    });
  } else {
    void showRecent();
    requestAnimationFrame(() => input.focus());
  }
  return h('div.search', null, form, hints, results);
}
