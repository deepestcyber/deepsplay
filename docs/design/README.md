# Design

`logo.svg` is the deepsplay logo. It is used only as the favicon:
`priv/static/images/favicon.svg` is a copy, and `priv/static/favicon.ico` is
rendered from it at 16, 32 and 48 px. The app shows the logo nowhere else.

The logo spells "lcd" with the letters of the font genotype (Fenotype,
fenotype.com), the font of the Deep Data Dump logo, on the same navy tile and
in the colours of the deep cyber banner:

- the l is raised by 228 font units, so that the top of its foot and the top
  of the bowl of the d lie on one line; l and d keep the font's spacing;
- the c, at full size, sits above that line, as far from it as the l is from
  the d at their closest (183 units), centred between the stems of l and d;
- l `#6171ff`, c `#fcfcfc`, d `#6a97ff` on `#00084a`.

The letters are the glyphs of the font as paths, one per letter
(`letter-l`, `letter-c`, `letter-d`), so the logo can be adjusted without the
font.

To render the favicon again after a change:

```sh
for z in 16 32 48; do
  inkscape docs/design/logo.svg --export-type=png --export-filename=/tmp/f$z.png -w $z -h $z
done
convert /tmp/f16.png /tmp/f32.png /tmp/f48.png priv/static/favicon.ico
cp docs/design/logo.svg priv/static/images/favicon.svg
```

The font is licensed for personal use only (1001Fonts FFP licence) and may
not be modified or built upon without the author's permission; whether the
logo is covered has not been checked yet.
