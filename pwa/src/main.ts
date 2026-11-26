// Sofa im Browser (docs/pwa.md): the app's controller - connection, routes, header, views.

import { Api, ApiError } from './api.ts';
import { codeFromHash, hostFromHash, loadConnection, saveConnection, shortName, type Connection } from './connection.ts';
import { clear, h } from './dom.ts';
import { Header } from './header.ts';
import { NetBar } from './netbar.ts';
import { renderPage } from './pages.ts';
import { Player } from './player.ts';
import { parseRoute, routeHash, type Route } from './router.ts';
import { connectScreen, pairScreen, settingsScreen, unreachableScreen } from './screens.ts';
import { searchScreen } from './search.ts';
import { skeletonPage } from './skeleton.ts';
import { closeSheet, openSheet, type SheetActions } from './sheet.ts';
import { Downloads } from './downloads.ts';
import { StatusFeed } from './status.ts';
import { Tv } from './tv.ts';
import { applyTheme } from './theme.ts';
import { forgetTiles, updateTiles, type TileHost } from './tiles.ts';
import { toast } from './toast.ts';
import type { Info, Item, MarkChange, Page } from './types.ts';

const REFRESH_AFTER_HIDDEN_MS = 5 * 60_000;
const VIEW_CACHE = 12;

interface View { el: HTMLElement; scrollY: number; theme: string; title: string }

class App {
  private connection: Connection | null = loadConnection();
  private api: Api | null = this.connection ? new Api(this.connection) : null;
  private info: Info | null = null;
  private player: Player | null = null;
  private tv: Tv | null = null;                // the TV's bar and "Auf dem Fernseher abspielen"
  private downloads: Downloads | null = null;
  private feed: StatusFeed | null = null;      // Sofa's status for both (long poll)
  private views = new Map<number, View>();     // history entry -> its rendered view (back restores it as left)
  private entry = 0;
  // history entry ids: from this load's start time on, so an id is never one an entry of an earlier load
  // of the page (before a reload) still carries - Back to such an entry must not find a view of this load
  private seq = Date.now();
  private hiddenAt = 0;
  private scannedCode: string | undefined;     // the code of the TV's pairing link, until the pairing screen used it
  private pairNotice: string | undefined;      // why the pairing screen shows (once)
  private readonly bar = document.getElementById('bar')!;
  private readonly main = document.getElementById('view')!;
  private readonly header = new Header(this.bar, (r) => this.navigate(r));
  private netbar: NetBar | null = null;

  start(): void {
    // the connect route came back with the full name: keep it, the token only for the same host; the
    // TV's pairing link (QR code) names the code too - paired with that code at once
    const learned = hostFromHash(location.hash);
    if (learned) {
      const keep = this.connection?.host === learned ? this.connection.token : undefined;
      this.setConnection({ host: learned, ...(keep ? { token: keep } : {}) });
      if (!keep) this.scannedCode = codeFromHash(location.hash) ?? undefined;
      history.replaceState({ entry: ++this.seq }, '', keep ? '#/' : '#/pair');
    } else {
      history.replaceState({ entry: ++this.seq, ...(history.state ?? {}) }, '', location.hash || '#/');
    }
    this.entry = (history.state as { entry?: number } | null)?.entry ?? this.seq;
    window.addEventListener('popstate', (e) => this.onPop(e));
    addEventListener('online', () => this.feed?.refresh());
    // reloaded while a video played: its player is gone, so is its history entry's meaning - one
    // step back to the page it was opened from (else Back would seem to do nothing once)
    if ((history.state as { player?: boolean } | null)?.player) { history.back(); return; }
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { this.hiddenAt = Date.now(); return; }
      if (this.hiddenAt && Date.now() - this.hiddenAt > REFRESH_AFTER_HIDDEN_MS && !this.player) void this.render(true);
    });
    void this.render(true);
  }

  private setConnection(c: Connection | null): void {
    this.stopServices();
    this.connection = c;
    this.api = c ? new Api(c) : null;
    this.info = null;
    this.views.clear();
    saveConnection(c);
  }

  // paired with a Sofa: its status (the TV, downloads) follows from now on
  private startServices(api: Api): void {
    if (this.feed) return;
    const statusChanged = (): void => this.feed?.refresh();
    const tv = this.tv ??= new Tv({ api, toast, statusChanged });
    const downloads = this.downloads = new Downloads({ api, toast, statusChanged });
    const netbar = this.netbar ??= new NetBar(() => this.feed?.refresh());
    const name = shortName(api.connection.host);
    this.feed = new StatusFeed(api, (s) => { tv.update(s.tv); downloads.track(s.downloads); }, () => this.lostPairing(),
      (ok) => { if (ok) netbar.hide(); else netbar.show(name); });
    this.feed.start();
  }

  private stopServices(): void {
    this.feed?.stop();
    this.feed = null;
    this.netbar?.hide();
    this.downloads = null;
    this.tv?.reset();
  }

  navigate(r: Route, replace = false): void {
    closeSheet();
    this.remember();
    const hash = routeHash(r);
    if (replace) history.replaceState({ entry: this.entry }, '', hash);
    else { this.entry = ++this.seq; history.pushState({ entry: this.entry }, '', hash); }
    void this.render(true);
  }

  private remember(): void {
    const v = this.views.get(this.entry);
    if (v) v.scrollY = scrollY;
  }

  private onPop(e: PopStateEvent): void {
    if (this.player) { const p = this.player; this.player = null; p.close(); return; }
    if (closeSheet()) { /* the sheet had no entry of its own: just closed */ }
    this.remember();
    const st = e.state as { entry?: number } | null;
    this.entry = st?.entry ?? ++this.seq;
    void this.render(false);
  }

  // fresh: build the view anew; else the remembered view of this history entry if there is one
  private async render(fresh: boolean): Promise<void> {
    const route = parseRoute(location.hash);
    const entry = this.entry;
    const kept = this.views.get(entry);
    if (!fresh && kept) { this.show(kept, route); requestAnimationFrame(() => scrollTo(0, kept.scrollY)); return; }

    if (!this.connection || !this.api || route.name === 'connect') { this.screen(connectScreen(this.connection ? shortName(this.connection.host) : '', (host) => this.useHost(host))); return; }
    const api = this.api;
    if (!this.connection.token || route.name === 'pair') {
      if (this.connection.token && route.name === 'pair') { this.navigate({ name: 'home' }, true); return; }
      const scanned = this.scannedCode, notice = this.pairNotice;
      this.scannedCode = this.pairNotice = undefined;   // once: a wrong or expired code is typed again
      this.screen(pairScreen(api, (token) => this.paired(token), () => this.otherHost(), scanned, notice));
      return;
    }
    if (!this.info) {
      this.loading(route.name === 'settings' || route.name === 'search' ? undefined : route);
      try { this.info = await api.info(); } catch (e) { this.failed(e); return; }
      this.header.build(this.info);
      this.startServices(api);
    }
    if (route.name === 'settings') {
      this.screen(settingsScreen(this.connection, this.info.device, '', () => this.unpair(), () => this.otherHost()), true);
      void api.hello().then((hi) => { const dd = this.main.querySelector('dd.version'); if (dd) dd.textContent = hi.version || '–'; }).catch(() => undefined);
      return;
    }
    if (route.name === 'search') {
      const app = this.info.apps.find((a) => a.id === route.app && a.search);
      if (!app) { this.navigate({ name: 'home' }, true); return; }
      const el = searchScreen(api, app, route.q, this.tileHost(), (q) => this.navigate({ name: 'search', app: app.id, q }, !!route.q));
      this.put({ el, scrollY: 0, theme: app.id, title: `Suche · ${app.name}` }, route, entry);
      return;
    }
    this.loading(route);
    let page: Page;
    try {
      page = await this.load(api, route);
    } catch (e) {
      if (entry !== this.entry) return;
      if (e instanceof ApiError && e.status === 401) { this.lostPairing(); return; }
      if (e instanceof ApiError && e.unreachable) { this.failed(e); return; }
      const msg = e instanceof Error ? e.message : 'Der Inhalt konnte nicht geladen werden.';
      this.screen(h('div.screen', null, h('div.screen-card', null, h('h1', null, 'Das hat nicht geklappt'), h('p.lead', null, msg),
        h('div.form', null,
          h('button.button.primary', { type: 'button', onclick: () => void this.render(true) }, 'Erneut versuchen'),
          h('button.button', { type: 'button', onclick: () => this.navigate({ name: 'home' }) }, 'Zur Startseite')))), true);
      return;
    }
    if (entry !== this.entry) return;   // the user went on meanwhile
    const theme = page.theme ?? (route.name === 'app' ? route.id : route.name === 'page' ? route.theme : undefined) ?? 'home';
    const title = page.title ?? (route.name === 'page' || route.name === 'show' ? route.title : undefined) ?? (route.name === 'app' ? this.appName(route.id) : 'Sofa');
    forgetTilesOfGoneViews(this.views);
    const el = renderPage(page, this.tileHost(theme), { showTitle: route.name !== 'home' });
    this.put({ el, scrollY: 0, theme, title: title ?? 'Sofa' }, route, entry);
    scrollTo(0, 0);
  }

  private load(api: Api, r: Route): Promise<Page> {
    switch (r.name) {
      case 'app': return api.app(r.id);
      case 'page': return api.page(r.handle);
      case 'show': return api.show(r.ref, r.title);
      default: return api.home();
    }
  }

  private put(v: View, route: Route, entry: number): void {
    this.views.set(entry, v);
    while (this.views.size > VIEW_CACHE) this.views.delete(this.views.keys().next().value!);
    this.show(v, route);
  }

  private show(v: View, route: Route): void {
    applyTheme(document.documentElement, this.info?.themes[v.theme] ?? this.info?.themes['home']);
    v.el.classList.toggle('arrived', !!this.main.querySelector(':scope > .skeleton'));
    clear(this.main);
    this.main.append(v.el);
    document.title = v.title === 'Sofa' ? 'Sofa' : `${v.title} – Sofa`;
    if (this.info) this.header.update(this.info, route, v.theme);
  }

  private screen(el: HTMLElement, withBar = false): void {
    applyTheme(document.documentElement, this.info?.themes['home']);
    this.bar.hidden = !withBar;
    clear(this.main);
    this.main.append(el);
    if (withBar && this.info) this.header.update(this.info, parseRoute(location.hash), 'home');
  }

  // While a page loads: its shape in its own colours (the theme of the app it belongs to, where known
  // before the answer), so neither the colours nor the layout jump when it arrives
  private loading(route?: Route): void {
    const theme = !route ? 'home' : route.name === 'app' ? route.id : route.name === 'page' ? route.theme : route.name === 'home' ? 'home' : undefined;
    const t = theme ? this.info?.themes[theme] : undefined;
    if (t) applyTheme(document.documentElement, t);
    if (route && this.info) this.header.update(this.info, route, theme && t ? theme : 'home');
    clear(this.main);
    // a heading only where the page will have one (a folder's or a show's page; an app's starts with its shelves)
    this.main.append(route ? skeletonPage({ showTitle: route.name === 'page' || route.name === 'show' }) : h('div.loading', { 'aria-label': 'Lädt' }));
  }

  private failed(e: unknown): void {
    if (e instanceof ApiError && e.status === 401) { this.lostPairing(); return; }
    const err = e instanceof ApiError ? e : new ApiError(0, 'Sofa ist gerade nicht erreichbar.');
    const api = this.api!;
    this.screen(unreachableScreen(this.connection!, err, () => api.hello(), () => void this.render(true), () => this.otherHost()));
  }

  private appName(id: string): string | undefined { return this.info?.apps.find((a) => a.id === id)?.name; }

  private tileHost(theme = 'home'): TileHost {
    const api = this.api!;
    return {
      api,
      activate: (item, tile) => this.activate(item, tile, theme),
      menu: (item, tile) => openSheet(item, this.sheetActions(theme), tile),
    };
  }

  private sheetActions(theme: string): SheetActions {
    return {
      play: (item, fromStart) => this.play(item, fromStart),
      toTV: (item) => void this.tv?.send(item),
      mark: (item, change) => this.mark(item, change),
      download: (item, action) => this.downloads?.act(item, action),
      open: (item) => this.openFolder(item, theme),
      openShow: (item) => { if (item.showRef) this.navigate({ name: 'show', ref: item.showRef, ...(item.channel ? { title: item.channel } : {}) }); },
      imageURL: (p, w) => this.api?.image(p, w),
    };
  }

  private activate(item: Item, tile: HTMLElement, theme: string): void {
    switch (item.kind) {
      case 'video':
        if (item.drm) { openSheet(item, this.sheetActions(theme), tile); return; }
        this.play(item, false);
        return;
      case 'live': this.play(item, false); return;
      case 'folder': this.openFolder(item, theme); return;
      case 'action':
        if (item.open === 'app' && item.arg) this.navigate({ name: 'app', id: item.arg });
        else if (item.open === 'search' && item.arg) this.navigate({ name: 'search', app: item.arg });
        return;
    }
  }

  private openFolder(item: Item, theme: string): void {
    const t = item.theme ?? theme;
    if (item.page) this.navigate({ name: 'page', handle: item.page, ...(item.title ? { title: item.title } : {}), theme: t });
    else if (item.id) this.navigate({ name: 'show', ref: item.id, ...(item.title ? { title: item.title } : {}) });
  }

  private play(item: Item, fromStart: boolean): void {
    if (!this.api || this.player) return;
    closeSheet();
    this.remember();
    history.pushState({ entry: this.entry, player: true }, '', location.hash);
    const p = new Player({
      api: this.api,
      closed: (it) => { if (this.player === p) this.player = null; void this.refresh(it); },
      toast,
      // the browser's player closes first (its last report), then the TV opens it there
      toTV: (it, at) => { if (this.player === p) history.back(); void this.tv?.send(it, at !== undefined ? { at } : {}); },
    }, item, fromStart);
    this.player = p;
    void p.open();
  }

  // The item's state after a playback (progress, watched): its tiles everywhere
  private async refresh(item: Item): Promise<void> {
    if (!this.api || !item.d) return;
    try { updateTiles((await this.api.mark(item, {})).item); } catch { /* stays as it was */ }
  }

  private async mark(item: Item, change: MarkChange): Promise<void> {
    if (!this.api) return;
    try {
      const r = await this.api.mark(item, change);
      updateTiles(r.item);
      const text = change.later !== undefined ? (change.later ? 'Zu „Später ansehen“ hinzugefügt' : 'Aus „Später ansehen“ entfernt')
        : change.watched !== undefined ? (change.watched ? 'Als gesehen markiert' : 'Als ungesehen markiert')
        : change.follow !== undefined ? (change.follow ? 'Du folgst jetzt dieser Sendung' : 'Du folgst nicht mehr')
        : change.forget ? 'Aus „Weiterschauen“ entfernt' : '';
      if (text) toast(text);
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Das hat nicht geklappt.');
    }
  }

  private useHost(host: string): void {
    const keep = this.connection?.host === host ? this.connection.token : undefined;
    this.setConnection({ host, ...(keep ? { token: keep } : {}) });
    this.navigate(keep ? { name: 'home' } : { name: 'pair' }, true);
  }

  private paired(token: string): void {
    if (!this.connection) return;
    this.setConnection({ ...this.connection, token });
    this.navigate({ name: 'home' }, true);
  }

  // Sofa no longer knows this device's token (removed on the TV): pair again, saying why
  private lostPairing(notice = 'Dieses Gerät wurde am Fernseher getrennt. Bitte mit einem neuen Code wieder verbinden.'): void {
    if (!this.connection) return;
    this.pairNotice = notice || undefined;
    this.setConnection({ host: this.connection.host });
    this.navigate({ name: 'pair' }, true);
  }

  private async unpair(): Promise<void> {
    try { await this.api?.unpair(); } catch { /* the token goes either way */ }
    this.lostPairing('');
  }

  private otherHost(): void {
    this.setConnection(null);
    this.navigate({ name: 'connect' }, true);
  }
}

// Tiles of views no longer kept are not updated any more
function forgetTilesOfGoneViews(views: Map<number, View>): void {
  if (views.size === 0) forgetTiles();
}

new App().start();

if ('serviceWorker' in navigator && location.protocol === 'https:') {
  addEventListener('load', () => { navigator.serviceWorker.register('sw.js').catch(() => undefined); });
}
