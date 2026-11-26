// The toast: a short confirmation at the bottom (above the TV's bar), or at the top while a sheet is
// open so it never covers the sheet's buttons. One at a time; a newer one replaces it.

import { h } from './dom.ts';

const SHOW_MS = 2800;
let timer: ReturnType<typeof setTimeout> | null = null;

function element(): HTMLElement {
  let t = document.getElementById('toast');
  if (!t) { t = h('div', { id: 'toast', role: 'status', 'aria-live': 'polite' }); document.body.append(t); }
  return t;
}

export function toast(text: string): void {
  const t = element();
  t.textContent = text;
  t.classList.add('show');
  if (timer) clearTimeout(timer);
  timer = setTimeout(hideToast, SHOW_MS);
}

export function hideToast(): void {
  if (timer) { clearTimeout(timer); timer = null; }
  document.getElementById('toast')?.classList.remove('show');
}
