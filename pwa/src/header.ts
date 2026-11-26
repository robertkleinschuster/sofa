// The header: back, the page's wordmark or logo with its header mark, the apps, search, settings.
// Built once per connection; each view only updates it (current app, brand, search target), so the
// header never re-lays out between pages and its buttons keep their places.

import { clear, h, icon, ICONS } from './dom.ts';
import { logoURL } from './logos.ts';
import { routeHash, type Route } from './router.ts';
import type { Info } from './types.ts';

export class Header {
  constructor(private bar: HTMLElement, private go: (r: Route) => void) {}

  build(info: Info): void {
    clear(this.bar);
    this.bar.hidden = false;
    const link = (r: Route, app: string, label: string): HTMLElement => h('a.app-link', {
      href: routeHash(r), dataset: { app }, onclick: (e: Event) => { e.preventDefault(); this.go(r); },
    }, label);
    const nav = h('nav.apps', { 'aria-label': 'Apps' },
      link({ name: 'home' }, 'home', 'Start'),
      ...info.apps.map((a) => link({ name: 'app', id: a.id }, a.id, a.name)));
    this.bar.append(
      h('button.icon-button.back', { type: 'button', 'aria-label': 'Zurück', title: 'Zurück', onclick: () => history.back() }, icon(ICONS.back)),
      h('a.brand', { href: '#/', 'aria-label': 'Sofa – Start', onclick: (e: Event) => { e.preventDefault(); this.go({ name: 'home' }); } }),
      nav,
      h('div.bar-actions', null,
        h('button.icon-button.search-button', { type: 'button', 'aria-label': 'Suchen', title: 'Suchen' }, icon(ICONS.search)),
        h('button.icon-button.settings-button', {
          type: 'button', 'aria-label': 'Einstellungen', title: 'Einstellungen', onclick: () => this.go({ name: 'settings' }),
        }, icon(ICONS.gear))));
  }

  update(info: Info, route: Route, theme: string): void {
    this.bar.hidden = false;
    const t = info.themes[theme] ?? info.themes['home'];
    const brand = this.bar.querySelector<HTMLElement>('.brand');
    if (brand && t) {
      const key = `${t.wordmark ?? 'Sofa'}|${t.logo ?? ''}|${t.headerMark}`;
      if (brand.dataset['key'] !== key) {   // the same brand stays as it is (no logo fading in again)
        brand.dataset['key'] = key;
        clear(brand);
        const word = h('span.brand-word', null, t.wordmark ?? 'Sofa');
        brand.append(word);
        if (t.logo) {
          void logoURL(t.logo, t.logoVariant ?? 0).then((u) => {
            if (!u || !word.isConnected) return;
            word.replaceWith(h('img.brand-logo', { src: u, alt: t.wordmark ?? '' }));
          });
        }
        brand.dataset['mark'] = t.headerMark;
      }
    }
    const appOf = route.name === 'app' ? route.id : route.name === 'search' ? route.app : theme;
    for (const a of this.bar.querySelectorAll<HTMLElement>('.app-link')) {
      const on = route.name === 'home' ? a.dataset['app'] === 'home' : a.dataset['app'] === appOf && route.name !== 'settings';
      a.classList.toggle('current', on);
      if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    }
    const back = this.bar.querySelector<HTMLElement>('.back');
    if (back) back.hidden = route.name === 'home';
    // search: the current app's, else the first app with one (Home searches YouTube on the TV too).
    // Not needed: invisible but in its place, so the settings button never moves.
    const searchApp = info.apps.find((a) => a.id === appOf && a.search) ?? info.apps.find((a) => a.search);
    const sb = this.bar.querySelector<HTMLButtonElement>('.search-button');
    if (sb) {
      const off = !searchApp || route.name === 'search';
      sb.classList.toggle('off', off);
      sb.tabIndex = off ? -1 : 0;
      sb.setAttribute('aria-hidden', off ? 'true' : 'false');
      sb.onclick = searchApp && !off ? () => this.go({ name: 'search', app: searchApp.id }) : null;
      if (searchApp) { sb.title = `${searchApp.name} durchsuchen`; sb.setAttribute('aria-label', sb.title); }
    }
  }
}
