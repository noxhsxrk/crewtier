#!/usr/bin/env python3
"""Render the README's animated charts.

    python3 assets/demo/charts.py      # writes assets/demo/savings.gif and assets/demo/flow.gif

Needs Pillow. savings.gif uses the numbers from `crewtier bench` runs (see README, "Does it save anything?").
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent
BG = (9, 15, 22)
CARD = (14, 21, 31)
LINE = (30, 41, 56)
FG = (226, 232, 240)
DIM = (128, 141, 158)
LIME = (202, 249, 102)
SLATE = (74, 88, 106)
AMBER = (245, 199, 107)
RED = (255, 118, 118)
CYAN = (125, 211, 252)

FONTS = "/usr/share/fonts/truetype/dejavu/"


def f(size, bold=False, mono=False):
    name = ("DejaVuSansMono" if mono else "DejaVuSans") + ("-Bold" if bold else "") + ".ttf"
    for p in (FONTS + name, "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            pass
    return ImageFont.load_default()


def ease(t):  # ease-out cubic
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def save(frames, durs, name):
    q = [im.convert("P", palette=Image.Palette.ADAPTIVE, colors=128) for im in frames]
    q[0].save(OUT / name, save_all=True, append_images=q[1:], duration=durs, loop=0, optimize=True, disposal=1)
    print(f"{name}: {len(q)} frames, {sum(durs) / 1000:.1f}s, {(OUT / name).stat().st_size // 1024} KB")


# ---------------------------------------------------------------- savings chart
# Lead's cost with crewtier, as % of the lead doing the same task alone (100 = no change).
ROWS = [
    ("Big task, new project", "400–900 lines of code · 4 runs", 29),
    ("Big task, existing repo", "~500 lines of code · 2 runs", 63),
    ("Mid task", "~150 lines · the lead does it itself", 102),
    ("Small task", "~50 lines · the lead does it itself", 110),
]


def savings_gif():
    W, H = 980, 470
    X0, X1 = 330, 900          # bar area: 0% .. 120%
    scale = (X1 - X0) / 120
    top, gap = 120, 82
    T, TB, S, NB = f(22, True), f(15, True), f(13), f(15, True, mono=True)
    frames, durs = [], []
    n = 34
    for k in range(n + 1):
        im = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(im)
        d.rounded_rectangle([10, 10, W - 10, H - 10], 16, fill=CARD)
        d.text((40, 34), "Lead's cost with crewtier", font=T, fill=FG)
        d.text((40, 66), "compared with the same lead doing the same task alone (Claude Opus as lead)", font=S, fill=DIM)
        # 100% reference line
        x100 = X0 + 100 * scale
        for y in range(top - 20, top + gap * len(ROWS) - 20, 8):
            d.line([x100, y, x100, y + 4], fill=SLATE, width=1)
        d.text((x100 - 32, top - 40), "alone = 100%", font=S, fill=DIM)
        for i, (label, sub, pct) in enumerate(ROWS):
            y = top + i * gap
            d.text((40, y + 2), label, font=TB, fill=FG)
            d.text((40, y + 24), sub, font=S, fill=DIM)
            d.rounded_rectangle([X0, y + 6, X1, y + 34], 6, fill=LINE)
            t = ease((k - i * 3) / (n - 12))
            v = pct * t
            col = LIME if pct < 90 else (DIM if pct <= 105 else AMBER)
            if v > 0:
                d.rounded_rectangle([X0, y + 6, X0 + max(12, v * scale), y + 34], 6, fill=col)
            if t > 0:
                txt = f"{round(v)}%"
                tx = X0 + v * scale + 10
                if tx + 60 > W - 20:
                    tx = X0 + v * scale - 60
                d.text((tx, y + 11), txt, font=NB, fill=FG if col != LIME or tx > X0 + v * scale else BG)
                if pct < 90 and t >= 1:
                    d.text((tx + 52, y + 11), f"{100 - pct}% less", font=TB, fill=LIME)
        d.text((40, H - 46), "Worker usage is not included: it comes out of each worker's own plan.", font=S, fill=DIM)
        frames.append(im)
        durs.append(40 if k < n else 5000)
    save(frames, durs, "savings.gif")


# ---------------------------------------------------------------- flow animation
NODES = [  # label, sub, colour
    ("You", "ask for a feature", FG),
    ("Lead", "writes the spec", CYAN),
    ("crewtier do", "one call", LIME),
    ("Worker", "writes the code", AMBER),
    ("Check", "runs your test", FG),
    ("Commit", "one-line result", LIME),
]


def flow_gif():
    W, H = 980, 270
    bw, bh, y0 = 138, 74, 80
    xs = [36 + i * 154 for i in range(len(NODES))]
    TB, S, SM = f(16, True), f(12), f(13, True, mono=True)
    frames, durs = [], []

    def base(active, note=None, fail=False, loop=0.0):
        im = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(im)
        d.rounded_rectangle([10, 10, W - 10, H - 10], 16, fill=CARD)
        for i in range(len(NODES) - 1):
            a, b = xs[i] + bw, xs[i + 1]
            d.line([a + 4, y0 + bh / 2, b - 6, y0 + bh / 2], fill=SLATE, width=2)
            d.polygon([(b - 6, y0 + bh / 2 - 5), (b, y0 + bh / 2), (b - 6, y0 + bh / 2 + 5)], fill=SLATE)
        # retry loop Check -> Worker
        lx0, lx1 = xs[3] + bw / 2, xs[4] + bw / 2
        ly = y0 + bh + 34
        lc = RED if fail else LINE
        d.line([lx1, y0 + bh, lx1, ly], fill=lc, width=2)
        d.line([lx1, ly, lx0, ly], fill=lc, width=2)
        d.line([lx0, ly, lx0, y0 + bh + 6], fill=lc, width=2)
        d.polygon([(lx0 - 5, y0 + bh + 8), (lx0, y0 + bh + 1), (lx0 + 5, y0 + bh + 8)], fill=lc)
        d.text(((lx0 + lx1) / 2 - 82, ly + 6), "fail: fix round, then tier up", font=S, fill=RED if fail else DIM)
        for i, (lab, sub, col) in enumerate(NODES):
            x = xs[i]
            on = i == active
            d.rounded_rectangle([x, y0, x + bw, y0 + bh], 12, fill=(24, 34, 48) if on else BG,
                                outline=col if on else LINE, width=3 if on else 2)
            tw = d.textlength(lab, font=TB)
            d.text((x + (bw - tw) / 2, y0 + 16), lab, font=TB, fill=col if on else FG)
            sw = d.textlength(sub, font=S)
            d.text((x + (bw - sw) / 2, y0 + 44), sub, font=S, fill=DIM)
        if loop:
            px, py = lx1 + (lx0 - lx1) * loop, ly
            d.ellipse([px - 6, py - 6, px + 6, py + 6], fill=RED)
        if note:
            d.text((30, 34), note, font=SM, fill=LIME if not fail else RED)
        return im, d

    def travel(i, note, steps=9):
        for s in range(steps + 1):
            im, d = base(i, note)
            t = ease(s / steps)
            a, b = xs[i] + bw, xs[i + 1]
            px = a + (b - a) * t
            d.ellipse([px - 6, y0 + bh / 2 - 6, px + 6, y0 + bh / 2 + 6], fill=LIME)
            frames.append(im); durs.append(45)

    def hold(i, note, ms, fail=False):
        im, _ = base(i, note, fail)
        frames.append(im); durs.append(ms)

    notes = [
        "you › Add CSV export to the reports page, with tests",
        "lead › big, decided, checkable → hand it off in one call",
        "$ crewtier do t2-normal --spec spec.md --commit \"Add CSV export\"",
        "codex/gpt-6.1-sol writing 412 lines in 5 files …",
        "Done when: pnpm test reports  →  FAIL (1 test)",
    ]
    for i in range(3):
        hold(i, notes[i], 900); travel(i, notes[i])
    hold(3, notes[3], 1100); travel(3, notes[3])
    hold(4, notes[4], 900, fail=True)
    for s in range(13):
        im, _ = base(4, "fix round: the worker gets the failing output", fail=True, loop=ease(s / 12))
        frames.append(im); durs.append(45)
    hold(3, "codex fixes the failing test", 900)
    travel(3, "codex fixes the failing test")
    hold(4, "Done when: pnpm test reports  →  PASS", 900)
    travel(4, "Done when: pnpm test reports  →  PASS")
    hold(5, "D1 PASS codex/gpt-6.1-sol · 412 lines (5 files) · 4m02s · commit 4e1c2ab", 3800)
    save(frames, durs, "flow.gif")


if __name__ == "__main__":
    savings_gif()
    flow_gif()
