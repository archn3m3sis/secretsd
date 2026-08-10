#!/usr/bin/env python3
"""Render an analog clock face as braille dots.

WHY BRAILLE. The U+2800 block gives four addressable dots per character cell in
two columns, so a terminal row becomes a 2x4 pixel block. A cell is about twice
as tall as it is wide, and braille packs 4 dots into that height against 2
across, which means a single dot is very nearly SQUARE. A circle drawn in dot
space is therefore a circle on screen, not an ellipse — which is the whole
reason this is drawable at all.

usage: clock.py HOUR MINUTE [DOTS]
    HOUR    0-23
    MINUTE  0-59
    DOTS    canvas size in dots, rounded to a multiple of 8 (default 48)

Prints the face on stdout, one line per character row, nothing else. The caller
owns all colour — this deliberately emits no escape sequences, so it can be
padded, indented, and tinted by the TUI without parsing anything back out.
"""

import math
import sys

# bit weights: BRAILLE[dx][dy] for a 2-wide, 4-tall cell
BRAILLE = ((0x01, 0x02, 0x04, 0x40),
           (0x08, 0x10, 0x20, 0x80))


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray(w * h)

    def set(self, x, y):
        x, y = int(round(x)), int(round(y))
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = 1

    def line(self, x0, y0, x1, y1, weight=1):
        # sampled rather than Bresenham: the hands are short and this keeps
        # them visually even in density at every angle. `weight` draws parallel
        # offset copies — a one-dot hand disappears against the tick marks.
        steps = int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length        # unit normal
        offsets = [0.0] if weight <= 1 else [(k - (weight - 1) / 2.0) * 0.8
                                             for k in range(weight)]
        for off in offsets:
            ox, oy = nx * off, ny * off
            for i in range(steps + 1):
                t = i / steps
                self.set(x0 + dx * t + ox, y0 + dy * t + oy)

    def disc(self, cx, cy, r):
        rr = r * r
        for y in range(int(cy - r), int(cy + r) + 1):
            for x in range(int(cx - r), int(cx + r) + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= rr:
                    self.set(x, y)

    def ring(self, cx, cy, r, thick=1.0):
        # walk the circumference by angle; stepping by pixel would leave gaps at
        # the top and bottom where dy/dx blows up
        steps = int(2 * math.pi * r * 3) + 8
        for i in range(steps):
            a = 2 * math.pi * i / steps
            for t in range(int(thick * 2) + 1):
                rr = r - t / 2.0
                self.set(cx + rr * math.cos(a), cy + rr * math.sin(a))

    def rows(self):
        out = []
        for cy in range(0, self.h, 4):
            line = []
            for cx in range(0, self.w, 2):
                bits = 0
                for dx in range(2):
                    for dy in range(4):
                        x, y = cx + dx, cy + dy
                        if x < self.w and y < self.h and self.px[y * self.w + x]:
                            bits |= BRAILLE[dx][dy]
                line.append(chr(0x2800 + bits))
            out.append("".join(line).rstrip() or " ")
        return out


def render(hour, minute, dots=48):
    dots = max(24, (dots // 8) * 8)
    c = Canvas(dots, dots)
    cx = cy = (dots - 1) / 2.0
    r = cx - 1

    # A thin bezel. Anything heavier and the tick marks weld themselves to it
    # and the face turns into a blob at 12, 3, 6 and 9.
    c.ring(cx, cy, r, thick=0.5)

    # Hour markers are DOTS, not strokes. A tick two dots long lands on
    # whichever dots the angle happens to hit, so at eleven o'clock it reads as
    # a smudge and at three o'clock as a dash — twelve marks, no two alike. A
    # disc is the same mark at every angle, and it suits the pixel aesthetic.
    for i in range(12):
        a = math.radians(i * 30 - 90)
        rr = r - 4.0
        c.disc(cx + rr * math.cos(a), cy + rr * math.sin(a),
               1.5 if i % 3 == 0 else 0.9)

    # hands. The hour hand advances with the minutes — a clock reading 09:59
    # with the short hand nailed to the 9 looks broken to anyone who has ever
    # owned a watch.
    ha = math.radians((hour % 12 + minute / 60.0) * 30 - 90)
    ma = math.radians(minute * 6 - 90)
    c.line(cx, cy, cx + r * 0.46 * math.cos(ha), cy + r * 0.46 * math.sin(ha), weight=3)
    c.line(cx, cy, cx + r * 0.70 * math.cos(ma), cy + r * 0.70 * math.sin(ma), weight=2)
    c.disc(cx, cy, 1.6)

    return c.rows()


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: clock.py HOUR MINUTE [DOTS]")
    try:
        h = int(sys.argv[1]) % 24
        m = int(sys.argv[2]) % 60
        d = int(sys.argv[3]) if len(sys.argv) > 3 else 48
    except ValueError:
        sys.exit("usage: clock.py HOUR MINUTE [DOTS]")
    print("\n".join(render(h, m, d)))


if __name__ == "__main__":
    main()
