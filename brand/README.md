# StudyLens visual system

The original StudyLens mascot **렌즈 (Lens)** is a deadpan learning assistant with
a small blue tuft and a magnifying glass. One character appears in four poses:
hero, reading text, inspecting a picture, and handing over code. Use short lines
that explain the real action; keep expressions flat and props recognizable.

Direction: [Questionable Hires](https://github.com/SoonGwan/questionable-hires/blob/main/assets/README.md)
and [issue #10](https://github.com/SoonGwan/StudyLens/issues/10). The reference
cast is used for drawing style, not copied as StudyLens characters.

## Montage semantic colors

| Role | Light | Dark |
| --- | --- | --- |
| `background.normal.alternative` | `#F7F7F8` | `#0F0F10` |
| `label.normal` | `#171719` | `#F7F7F8` |
| `label.neutral` | `#2E2F33` at 88% | `#C2C4C8` at 88% |
| `primary.normal` | `#0066FF` | `#3385FF` |

Use white for elevated example windows and text on blue. Separators use ink at
15% opacity. These are the same colors used by Questionable Hires, from
[Montage's semantic palette](https://montage.wanted.co.kr/docs/foundations/base-material/colors/semantic).
No Montage logo or bundled font is used; no affiliation is implied.

Typography uses the system stack: Helvetica Neue, Arial, Apple SD Gothic Neo,
Noto Sans KR, sans-serif. Use large, tightly spaced headings, quiet supporting
copy, generous space, thin dividers, and a single blue accent. Landing CSS tokens
live in `landing/style.css`.

## Assets and provenance

- `lens-poses-master.png`: original transparent four-pose sheet generated on
  2026-10-10 with built-in `image_gen.imagegen`. Exact prompt and reference are in
  [imagegen-prompt.json](imagegen-prompt.json).
- `landing/assets/lens-poses.webp`: delivery encoding of the complete sheet.
  CSS shows individual grid cells without repainting the artwork. Preserve alpha.
- `app-result.png`: rendered from the repository's real `ResultView`, using
  [result-example.txt](result-example.txt). This is an authored, fixed teaching
  example, not a live model response or a screen recording. The renderer creates
  an offscreen hosting view without accessing a user's screen or sending a request.
- `landing/assets/app-result.webp`: delivery encoding of that result view.
- `og-source.html`: editable 1200 × 630 sharing-card source; delivery image is
  `landing/assets/og-ko.png`.
- `landing/assets/favicon.svg`: native magnifier icon with the character's flat
  eyes; PNG sizes are 32 × 32 and 180 × 180.

Regenerate locally on macOS:

```sh
npm ci --prefix tools/landing
python3 -B scripts/render_app_result.py
node scripts/render_landing_assets.cjs
```

The renderer needs Swift and an installed Chrome. For a different Chrome path,
set `STUDYLENS_CHROME_PATH`. Ordinary static builds need only Python, with no Node,
Swift, image service, font CDN, or runtime package dependency.
