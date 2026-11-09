# Brand marks (res/logos/marks)

Square 256x256 RGBA PNGs drawn as round avatars / tiny app badges. Each mark is centred and scaled so that
its bounding box fits inside the inscribed circle (box diagonal <= ~80 % of 256 px; circular marks: diameter
<= 76-84 %), so a circle crop never cuts the mark. Where the brand mark itself is a filled square/box, that
colour fills the whole square; otherwise the background is transparent.

## Rendering

- Source SVGs were downloaded unmodified into a scratch directory (not committed).
- Each id: the SVG is embedded into a 256x256 wrapper SVG (optional clip window to drop a claim/suffix, optional
  full-square background colour taken from the logo itself), positioned by the bounding box of the visible ink,
  then rendered with `rsvg-convert` 2.58.5 (librsvg, MacPorts). No paths were redrawn or recoloured.
- Output re-encoded as 8-bit RGBA PNG (colour type 6) with adaptive row filters + zlib level 9 (Python stdlib).

## Licence status

All Commons files below are tagged **PD-textlogo** (public domain: below the threshold of originality) on
Wikimedia Commons, and almost all carry the Commons **trademark** notice. Public domain copyright status does not
affect trademark rights: the marks are used here only to identify the respective broadcaster/service.

## Files

| File | Source | Commons status | Rendering |
|---|---|---|---|
| `youtube.png` | [File:YouTube full-color icon (2024).svg](https://commons.wikimedia.org/wiki/File:YouTube_full-color_icon_(2024).svg) | PD-textlogo, trademark notice | transparent; box fit 86 %. Red play-button icon (2024 colours), not the wordmark. |
| `zdf.png` | [File:ZDF logo.svg](https://commons.wikimedia.org/wiki/File:ZDF_logo.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `ard.png` | [File:ARD 2019 logo.svg](https://commons.wikimedia.org/wiki/File:ARD_2019_logo.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %. Full ARD logo ("ARD" + circled 1), used for the ARD Mediathek app. |
| `orf.png` | [File:ORF logo.svg](https://commons.wikimedia.org/wiki/File:ORF_logo.svg) | PD-textlogo, trademark notice | bg #D32822; box fit 80 %. Brand red #D32822 extended to the full square; mark sized by the white "ORF" letters. |
| `ccc.png` | [File:Logo CCC.svg](https://commons.wikimedia.org/wiki/File:Logo_CCC.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %. Chaosknoten (black, transparent). Needs a light plate on dark UI. |
| `3sat.png` | [File:3sat 2019.svg](https://commons.wikimedia.org/wiki/File:3sat_2019.svg) | PD-textlogo, trademark notice | bg #e40a22; clip window 0,0,0.56,1 (fractions of the source); round fit 62 %. Clipped to the red square with the "3" (the "sat" lettering is left out); red #e40a22 extended to the full square. |
| `arte.png` | [File:Arte Logo 2026.svg](https://commons.wikimedia.org/wiki/File:Arte_Logo_2026.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `daserste.png` | [File:ARD 2019 logo.svg](https://commons.wikimedia.org/wiki/File:ARD_2019_logo.svg) | PD-textlogo, trademark notice | transparent; clip window 0.6,0,1,1 (fractions of the source); round fit 76 %. Clipped to the circled "1" of the same ARD 2019 file (Das Erste on-air mark). |
| `zdfneo.png` | [File:ZDFneo 2017.svg](https://commons.wikimedia.org/wiki/File:ZDFneo_2017.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `zdfinfo.png` | ZDF website sprite <https://www.zdf.de/_next/static/media/mediathek-logo-colored-icons-sprite.0k5dg4zkh4qos.svg>, symbol `#zdf-info-logo` (found on <https://www.zdf.de/sender/zdfinfo>) | Not on Commons in current design (Commons only has the 2011 logo). Taken from the broadcaster's own site; trademark of ZDF, no licence statement | transparent; box fit 80 %.  |
| `phoenix.png` | [File:Phoenix Logo 2018 ohne Claim.svg](https://commons.wikimedia.org/wiki/File:Phoenix_Logo_2018_ohne_Claim.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `kika.png` | [File:Kika 2012.svg](https://commons.wikimedia.org/wiki/File:Kika_2012.svg) | PD-textlogo, trademark notice | transparent; clip window 0,0,1,0.62 (fractions of the source); box fit 80 %. Clipped to the "KiKA" lettering; the "von ARD und ZDF" claim is left out. |
| `br.png` | [File:Logo Bayerischer Rundfunk 2024.svg](https://commons.wikimedia.org/wiki/File:Logo_Bayerischer_Rundfunk_2024.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `hr.png` | [File:Hessischer Rundfunk Logo 2023.svg](https://commons.wikimedia.org/wiki/File:Hessischer_Rundfunk_Logo_2023.svg) | PD-textlogo, trademark notice | transparent; clip window 0,0,0.4,1 (fractions of the source); box fit 80 %. Clipped to "hr" + ARD circled 1; the "Hessischer Rundfunk" text is left out. |
| `mdr.png` | [File:MDR Logo 2017.svg](https://commons.wikimedia.org/wiki/File:MDR_Logo_2017.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `ndr.png` | [File:NDR Logo.svg](https://commons.wikimedia.org/wiki/File:NDR_Logo.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `rbb.png` | [File:Rbb Logo 2017.08.svg](https://commons.wikimedia.org/wiki/File:Rbb_Logo_2017.08.svg) | PD-textlogo, trademark notice | bg #e31818; box fit 80 %. Red #e31818 extended to the full square; mark sized by the white "rbb" letters. |
| `sr.png` | [File:Saarländischer Rundfunk Logo 2023.svg](https://commons.wikimedia.org/wiki/File:Saarl%C3%A4ndischer_Rundfunk_Logo_2023.svg) | PD-textlogo, trademark notice | bg #007796; clip window 0,0,0.32,1 (fractions of the source); box fit 70 %. Clipped to the "SR" parallelogram; its teal #007796 extended to the full square. |
| `swr.png` | [File:SWR Logo 2023.svg](https://commons.wikimedia.org/wiki/File:SWR_Logo_2023.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `wdr.png` | [File:WDR Dachmarke.svg](https://commons.wikimedia.org/wiki/File:WDR_Dachmarke.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `radiobremen.png` | [File:Logo Radio Bremen.svg](https://commons.wikimedia.org/wiki/File:Logo_Radio_Bremen.svg) | PD-textlogo, trademark notice | transparent; clip window 0,0,0.17,1 (fractions of the source); round fit 76 %. Clipped to the red circle symbol; the "radiobremen" wordmark is left out. |
| `one.png` | [File:One 2022.svg](https://commons.wikimedia.org/wiki/File:One_2022.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `alpha.png` | [File:ARD-alpha logo 2019-01-07.svg](https://commons.wikimedia.org/wiki/File:ARD-alpha_logo_2019-01-07.svg) | PD-textlogo, trademark notice | transparent; clip window 0,0,0.72,1 (fractions of the source); box fit 80 %. Clipped to "alpha" + circled 1; the "HD" suffix is left out. |
| `tagesschau24.png` | [File:Tagesschau24-2012.svg](https://commons.wikimedia.org/wiki/File:Tagesschau24-2012.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %. Thin, dark-blue, wide wordmark; weak at avatar size. |
| `funk.png` | [File:Funk-Logo-2023.svg](https://commons.wikimedia.org/wiki/File:Funk-Logo-2023.svg) | PD-textlogo, trademark notice | bg #a952f7; box fit 80 %. Purple #a952f7 extended to the full square; mark sized by the white glyphs. |
| `orf1.png` | [File:ORF 1 2019.svg](https://commons.wikimedia.org/wiki/File:ORF_1_2019.svg) | PD-textlogo | transparent; box fit 80 %.  |
| `orf2.png` | [File:ORF2 logo n.svg](https://commons.wikimedia.org/wiki/File:ORF2_logo_n.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %.  |
| `orf3.png` | [File:ORF III 11.svg](https://commons.wikimedia.org/wiki/File:ORF_III_11.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %. ORF III logo (2011 design) with its translucent grey box; designed for dark backgrounds. |
| `orfs.png` | [File:ORF Sport + Logo 2024.svg](https://commons.wikimedia.org/wiki/File:ORF_Sport_+_Logo_2024.svg) | PD-textlogo, trademark notice | transparent; box fit 80 %. Very wide wordmark; small inside a circle. |

`zdf`, `3sat` and `arte` are shared by the app list and the station list (one file each).
