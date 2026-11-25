// The brands' logos (res/logos, copied at build time) in Sofa's variants (SFLogo.m): the white
// background of logos without alpha is cut out; "light text" turns dark achromatic pixels white (for
// dark surfaces); "white" turns everything white. Rendered once per variant into a data URL.

export const LOGO_ORIGINAL = 0, LOGO_LIGHT_TEXT = 1, LOGO_WHITE = 2;

// Pure: recolours straight (non-premultiplied) RGBA in place, as SFLogo.m's render() does.
export function recolor(px: Uint8ClampedArray, variant: number, knockWhite: boolean): void {
  for (let i = 0; i < px.length; i += 4) {
    const a = px[i + 3]!;
    if (!a) continue;
    let r = px[i]!, g = px[i + 1]!, b = px[i + 2]!;
    const lum = 0.299 * r + 0.587 * g + 0.114 * b;
    const sat = Math.max(r, g, b) - Math.min(r, g, b);
    if (knockWhite && lum > 240 && sat < 18 && a === 255) { px[i] = px[i + 1] = px[i + 2] = px[i + 3] = 0; continue; }
    if (variant === LOGO_WHITE) r = g = b = 255;
    else if (variant === LOGO_LIGHT_TEXT && lum < 90 && sat < 40) r = g = b = 255;
    px[i] = r; px[i + 1] = g; px[i + 2] = b;
  }
}

// A logo with no transparent pixel at all had a white background (the PNG had no alpha channel).
export function isOpaque(px: Uint8ClampedArray): boolean {
  for (let i = 3; i < px.length; i += 4) if (px[i] !== 255) return false;
  return true;
}

const cache = new Map<string, Promise<string | null>>();

export function logoURL(name: string, variant: number): Promise<string | null> {
  const key = `${name}#${variant}`;
  let p = cache.get(key);
  if (!p) {
    p = render(`logos/${encodeURIComponent(name)}.png`, variant);
    cache.set(key, p);
  }
  return p;
}

// The marks that exist (res/logos/marks, listed by build.mjs)
declare const __SOFA_MARKS__: string[] | undefined;
const MARKS = new Set<string>(typeof __SOFA_MARKS__ !== 'undefined' ? __SOFA_MARKS__ : []);

export function hasMark(name: string | undefined): boolean { return !!name && MARKS.has(name); }

export function markURL(name: string): string { return `logos/marks/${encodeURIComponent(name)}.png`; }

async function render(src: string, variant: number): Promise<string | null> {
  const img = new Image();
  img.decoding = 'async';
  img.src = src;
  try { await img.decode(); } catch { return null; }
  const canvas = document.createElement('canvas');
  canvas.width = img.naturalWidth; canvas.height = img.naturalHeight;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx) return src;
  ctx.drawImage(img, 0, 0);
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
  recolor(data.data, variant, isOpaque(data.data));
  ctx.putImageData(data, 0, 0);
  return canvas.toDataURL('image/png');
}
