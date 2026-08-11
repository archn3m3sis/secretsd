#!/usr/bin/env python3
"""Render each note system's mark as braille pixel art. usage: pkmart.py [NAME]

WHY A GENERATOR. The Obsidian crystal was hand-authored as two parallel bash
arrays — 22 columns of braille and a matching grid of region digits. That is
fine for one mark and unmaintainable for six: every nudge means re-typing a
10x22 grid of braille characters and keeping a second grid aligned with it by
eye.

Here each mark is drawn with primitives at DOT resolution (44x40 dots = 22x10
character cells), and the generator emits both grids. `--emit-shell` writes the
static bash arrays that pkm.sh actually uses, so the terminal never pays for
python at paint time.

REGIONS. Every dot carries a region digit 1-4, and each system maps those four
to its own palette. That is what lets one painter draw all six marks: the shape
comes from the bitmap, the colour identity from the palette.
"""

import sys

W, H = 44, 40                      # dots
BRAILLE = ((0x01, 0x02, 0x04, 0x40),
           (0x08, 0x10, 0x20, 0x80))


class Art:
    def __init__(self):
        self.px = [[0] * W for _ in range(H)]

    def set(self, x, y, reg):
        x, y = int(round(x)), int(round(y))
        if 0 <= x < W and 0 <= y < H:
            self.px[y][x] = reg

    def rect(self, x0, y0, x1, y1, reg, fill=False):
        x0, x1 = sorted((int(x0), int(x1)))
        y0, y1 = sorted((int(y0), int(y1)))
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if fill or y in (y0, y1) or x in (x0, x1):
                    self.set(x, y, reg)

    def line(self, x0, y0, x1, y1, reg):
        steps = int(max(abs(x1 - x0), abs(y1 - y0))) * 2 + 1
        for i in range(steps + 1):
            t = i / steps
            self.set(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, reg)

    def disc(self, cx, cy, r, reg):
        for y in range(int(cy - r) - 1, int(cy + r) + 2):
            for x in range(int(cx - r) - 1, int(cx + r) + 2):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    self.set(x, y, reg)

    def ring(self, cx, cy, r, reg, thick=1.0):
        import math
        steps = int(2 * math.pi * r * 3) + 8
        for i in range(steps):
            a = 2 * math.pi * i / steps
            for t in range(int(thick * 2) + 1):
                rr = r - t / 2.0
                self.set(cx + rr * math.cos(a), cy + rr * math.sin(a), reg)

    def poly(self, pts, reg):
        """Filled polygon by scanline — the crystal facets need this."""
        ys = [p[1] for p in pts]
        for y in range(int(min(ys)), int(max(ys)) + 1):
            xs = []
            for i in range(len(pts)):
                x0, y0 = pts[i]
                x1, y1 = pts[(i + 1) % len(pts)]
                if y0 == y1:
                    continue
                if min(y0, y1) <= y < max(y0, y1):
                    xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                for x in range(int(xs[i]), int(xs[i + 1]) + 1):
                    self.set(x, y, reg)

    def rows(self):
        art, reg = [], []
        for cy in range(0, H, 4):
            a, r = [], []
            for cx in range(0, W, 2):
                bits = 0
                best = 0
                counts = {}
                for dx in range(2):
                    for dy in range(4):
                        x, y = cx + dx, cy + dy
                        v = self.px[y][x] if (y < H and x < W) else 0
                        if v:
                            bits |= BRAILLE[dx][dy]
                            counts[v] = counts.get(v, 0) + 1
                if counts:
                    best = max(counts.items(), key=lambda kv: (kv[1], kv[0]))[0]
                a.append(chr(0x2800 + bits))
                r.append(str(best) if best else ".")
            art.append("".join(a))
            reg.append("".join(r))
        return art, reg


# --- the marks ---------------------------------------------------------------

def obsidian(a):
    """The crystal: four facets, tonally separated.

    NOTE: pkm.sh does not use this. The hand-authored crystal it already carries
    reads better than anything this generator produced — filled facets at 44x40
    dots come out as a blob, where the original's line work keeps the edges. It
    is kept here so the mark is regenerable if the format ever changes.
    """
    top   = [(22, 1), (30, 12), (22, 18), (13, 12)]
    left  = [(13, 12), (22, 18), (18, 36), (3, 20)]
    right = [(30, 12), (41, 20), (26, 36), (22, 18)]
    bot   = [(22, 18), (26, 36), (18, 36)]
    a.poly(top, 4); a.poly(left, 2); a.poly(right, 3); a.poly(bot, 1)


def plaintext(a):
    """A page with a folded corner and lines of text."""
    a.rect(9, 3, 34, 37, 3)
    a.line(28, 3, 34, 9, 3)
    a.poly([(28, 3), (34, 9), (28, 9)], 2)
    for i, y in enumerate(range(13, 34, 4)):
        a.rect(13, y, 30 - (6 if i % 3 == 2 else 0), y + 1, 1, fill=True)


def apple_notes(a):
    """A notepad: bound top strip, ruled lines below."""
    a.rect(7, 4, 37, 36, 3)
    a.rect(7, 4, 37, 11, 4, fill=True)
    for x in range(11, 35, 6):
        a.rect(x, 1, x + 1, 7, 2, fill=True)
    for y in range(16, 34, 5):
        a.rect(11, y, 33, y + 1, 1, fill=True)


def joplin(a):
    """A notebook seen edge-on, with its bookmark ribbon hanging out.

    The tile is an OUTLINE, not a fill. Filling it first and then drawing the
    ribbon on top just produced a solid block: at this resolution a shape only
    reads if the negative space survives.
    """
    a.rect(6, 4, 38, 36, 3)          # cover
    a.rect(7, 5, 37, 35, 3)          # inner rule, gives the edge weight
    a.rect(10, 8, 10, 33, 2, fill=True)   # spine
    a.rect(11, 8, 12, 33, 2, fill=True)
    for y in range(12, 32, 5):       # ruled lines
        a.rect(16, y, 33, y, 1, fill=True)
    # the ribbon, hanging past the bottom edge
    a.poly([(24, 4), (30, 4), (30, 30), (27, 25), (24, 30)], 4)


def cherrytree(a):
    """Two cherries on a stem with a leaf — the program's own emblem."""
    a.disc(15, 29, 7, 1)
    a.disc(30, 31, 6, 2)
    a.line(15, 22, 22, 8, 3)
    a.line(30, 25, 23, 9, 3)
    a.poly([(23, 8), (34, 3), (31, 11)], 4)


def notion(a):
    """The bordered N."""
    a.rect(6, 4, 38, 36, 3)
    a.rect(7, 5, 37, 35, 3)
    a.rect(13, 11, 16, 29, 4, fill=True)     # left stem
    a.rect(28, 11, 31, 29, 4, fill=True)     # right stem
    a.poly([(16, 11), (20, 11), (31, 29), (27, 29)], 2)   # diagonal


MARKS = {
    "obsidian":    obsidian,
    "plaintext":   plaintext,
    "apple-notes": apple_notes,
    "joplin":      joplin,
    "cherrytree":  cherrytree,
    "notion":      notion,
}


def render(name):
    a = Art()
    MARKS[name](a)
    return a.rows()


def main():
    args = [x for x in sys.argv[1:] if x != "--emit-shell"]
    if "--emit-shell" in sys.argv:
        print("# GENERATED by bin/lib/pkmart.py — do not hand-edit.")
        print("# Regenerate:  python3 bin/lib/pkmart.py --emit-shell > bin/lib/pkmart.sh")
        print("# Each mark is 22 cells wide by 10 tall; REG carries a region digit per")
        print("# cell, which each system's palette maps to its own four colours.")
        print()
        for name in MARKS:
            var = name.replace("-", "_").upper()
            art, reg = render(name)
            print("PKM_ART_%s=(" % var)
            for r in art:
                print('  "%s"' % r)
            print(")")
            print("PKM_REG_%s=(" % var)
            for r in reg:
                print('  "%s"' % r)
            print(")")
            print()
        return
    for name in (args or ["obsidian"]):
        art, _ = render(name)
        print("\n".join(art))


if __name__ == "__main__":
    main()
