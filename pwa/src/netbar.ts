// "Keine Verbindung": shown while Sofa's status has stopped answering (Tailscale off, the Mac asleep,
// out of reach), over the content that is still on screen - which stays usable as it was. Gone by
// itself as soon as Sofa answers again; "Erneut versuchen" asks at once.

import { h, icon, ICONS } from './dom.ts';

export class NetBar {
  private el: HTMLElement;
  private text: HTMLElement;

  constructor(retry: () => void) {
    this.text = h('span.netbar-text');
    this.el = h('div.netbar', { role: 'status', 'aria-live': 'polite', hidden: true },
      icon(ICONS.offline), this.text,
      h('button.netbar-retry', { type: 'button', onclick: retry }, 'Erneut versuchen'));
    document.body.append(this.el);
  }

  show(name: string): void {
    this.text.textContent = `Keine Verbindung zu „${name}“`;
    this.el.hidden = false;
    document.body.classList.add('net-off');
  }

  hide(): void {
    this.el.hidden = true;
    document.body.classList.remove('net-off');
  }
}
