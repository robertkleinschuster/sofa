// Sofa's design tokens (SFTheme, served by /api/info) as CSS custom properties. Fonts are the TV's
// faces by PostScript name where the device has them (Apple's can't be bundled), else the system's.

import type { Theme } from './types.ts';

const FALLBACK_FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';

// The base theme's values (SFTheme +base) for what a theme leaves out.
const BASE: Required<Pick<Theme, 'background' | 'backgroundTop' | 'surface' | 'text' | 'textDim' | 'accent' | 'accentText' | 'focus'>> = {
  background: 'rgba(16,17,20,1)', backgroundTop: 'rgba(28,31,38,1)', surface: 'rgba(36,39,46,1)',
  text: 'rgba(244,245,247,1)', textDim: 'rgba(244,245,247,0.6)', accent: 'rgba(255,255,255,1)',
  accentText: 'rgba(17,17,17,1)', focus: 'rgba(255,255,255,1)',
};

const declared = new Set<string>();

function fontFamily(sheet: CSSStyleSheet | null, postScript: string, weight: number): string {
  if (!postScript) return FALLBACK_FONT;
  const family = `sofa-${postScript.replace(/[^A-Za-z0-9-]/g, '')}`;
  if (!declared.has(family) && sheet) {
    declared.add(family);
    // local() by PostScript name and by the full name; the weight lets the fallback below match it
    const full = postScript.replace(/-/g, ' ');
    sheet.insertRule(`@font-face { font-family: "${family}"; src: local("${postScript}"), local("${full}"); font-weight: ${weight}; font-display: swap; }`, sheet.cssRules.length);
  }
  return `"${family}", ${FALLBACK_FONT}`;
}

export function themeVariables(t: Theme, sheet: CSSStyleSheet | null): Record<string, string> {
  const c = { ...BASE, ...stripUndefined(t) };
  return {
    '--bg': c.background,
    '--bg-top': c.backgroundTop,
    '--surface': c.surface,
    '--text': c.text,
    '--text-dim': c.textDim,
    '--accent': c.accent,
    '--accent-text': c.accentText,
    '--focus': c.focus,
    '--focus-text': t.focusText ?? (t.light ? 'rgba(255,255,255,1)' : 'rgba(17,17,17,1)'),
    '--progress': t.progress ?? (t.light ? c.accent : c.focus),
    '--seek': t.seekBar ?? c.accent,
    '--wordmark': t.wordmarkColor ?? c.text,
    '--header-mark': t.headerMarkColor ?? c.accent,
    '--corner': `${Math.max(0, t.corner ?? 10)}px`,
    '--font': fontFamily(sheet, t.fonts?.regular ?? '', 400),
    '--font-medium': fontFamily(sheet, t.fonts?.medium ?? '', 500),
    '--font-bold': fontFamily(sheet, t.fonts?.bold ?? '', 700),
    '--font-wordmark': fontFamily(sheet, t.fonts?.wordmark ?? '', 700),
    '--header-case': t.uppercaseHeaders ? 'uppercase' : 'none',
    '--scheme': t.light ? 'light' : 'dark',
  };
}

function stripUndefined<T extends object>(o: T): Partial<T> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null)) as Partial<T>;
}

let fontSheet: CSSStyleSheet | null = null;

export function applyTheme(root: HTMLElement, t: Theme | undefined): void {
  if (!t) return;
  if (!fontSheet && typeof document !== 'undefined') {
    const style = document.createElement('style');
    document.head.append(style);
    fontSheet = style.sheet;
  }
  for (const [k, v] of Object.entries(themeVariables(t, fontSheet))) root.style.setProperty(k, v);
  root.style.colorScheme = t.light ? 'light' : 'dark';
  root.dataset['light'] = t.light ? '1' : '0';
  const meta = document.querySelector('meta[name="theme-color"]');
  meta?.setAttribute('content', t.backgroundTop ?? t.background ?? BASE.backgroundTop);
}
