#!/usr/bin/env python3
"""Render the README demo GIFs (terminal recordings, scripted).

    python3 assets/demo/render.py          # writes setup.gif, task.gif and menu.gif (charts: charts.py)

Needs Pillow. The sessions below are scripted to show the flow; model names and timings are
illustrative, not a recording of a real run.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent
W, H = 980, 600
PAD_X, TOP = 28, 58
LINE_H = 21
FONT_SIZE = 15
ROWS = (H - TOP - 20) // LINE_H

BG = (9, 15, 22)
WIN = (14, 21, 31)
BAR = (20, 29, 42)
FG = (226, 232, 240)
DIM = (128, 141, 158)
LIME = (202, 249, 102)
SLATE = (154, 169, 184)
RED = (255, 118, 118)
AMBER = (245, 199, 107)
CYAN = (125, 211, 252)
COLORS = {"fg": FG, "dim": DIM, "lime": LIME, "slate": SLATE, "red": RED, "amber": AMBER, "cyan": CYAN}

def font(bold=False):
    for p in (["/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"] if bold else []) + \
             ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/System/Library/Fonts/Menlo.ttc"]:
        try:
            return ImageFont.truetype(p, FONT_SIZE)
        except OSError:
            pass
    return ImageFont.load_default()

F, FB = font(), font(True)
CW = F.getbbox("M")[2]

# A line is a list of (text, colour[, bold]) segments.
def seg(text, c="fg", b=False):
    return (text, c, b)

def parse(s):
    """Tiny markup: {lime}text{/} switches colour, {b} bold. Plain text = fg."""
    out, cur, bold, buf, i = [], "fg", False, "", 0
    while i < len(s):
        if s[i] == "{":
            j = s.index("}", i)
            tag = s[i + 1:j]
            if buf:
                out.append((buf, cur, bold)); buf = ""
            if tag == "/":
                cur, bold = "fg", False
            elif tag == "b":
                bold = True
            else:
                cur = tag
            i = j + 1
        else:
            buf += s[i]; i += 1
    if buf:
        out.append((buf, cur, bold))
    return out

class Term:
    def __init__(self, title):
        self.title = title
        self.lines = []          # list of segment lists
        self.frames, self.durs = [], []

    def render(self, cursor=True):
        im = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(im)
        d.rounded_rectangle([10, 10, W - 10, H - 10], 14, fill=WIN)
        d.rounded_rectangle([10, 10, W - 10, 46], 14, fill=BAR)
        d.rectangle([10, 32, W - 10, 46], fill=BAR)
        for k, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
            d.ellipse([28 + k * 20, 22, 40 + k * 20, 34], fill=c)
        tw = F.getbbox(self.title)[2]
        d.text(((W - tw) / 2, 20), self.title, font=F, fill=DIM)
        view = self.lines[-ROWS:]
        y = TOP
        for ln in view:
            x = PAD_X
            for text, c, b in ln:
                d.text((x, y), text, font=FB if b else F, fill=COLORS[c])
                x += CW * len(text)
            y += LINE_H
        if cursor and view:
            x = PAD_X + CW * sum(len(t) for t, _, _ in view[-1])
            d.rectangle([x + 1, y - LINE_H + 3, x + CW - 1, y - 3], fill=LIME)
        return im

    def snap(self, ms, cursor=True):
        self.frames.append(self.render(cursor)); self.durs.append(ms)

    def out(self, *lines, ms=70):
        for s in lines:
            self.lines.append(parse(s) if isinstance(s, str) else s)
            self.snap(ms, cursor=False)

    def type(self, prompt, text, ms=38, after=350):
        self.lines.append(parse(prompt))
        self.snap(250)
        step = 2
        for i in range(0, len(text), step):
            self.lines[-1] = parse(prompt) + [(text[: i + step], "fg", True)]
            self.snap(ms)
        self.snap(after)

    def pause(self, ms):
        self.snap(ms)

    def clear(self):
        self.lines = []

    def save(self, name):
        pal = Image.new("P", (1, 1))
        flat = []
        for c in [BG, WIN, BAR, FG, DIM, LIME, SLATE, RED, AMBER, CYAN, (255, 95, 86), (255, 189, 46), (39, 201, 63)]:
            flat += list(c)
        # anti-aliasing shades between text and background
        for base in [FG, DIM, LIME, SLATE, RED, AMBER, CYAN]:
            for t in (0.25, 0.5, 0.75):
                flat += [round(WIN[k] + (base[k] - WIN[k]) * t) for k in range(3)]
        flat += [0] * (768 - len(flat))
        pal.putpalette(flat)
        q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in self.frames]
        q[0].save(OUT / name, save_all=True, append_images=q[1:], duration=self.durs, loop=0, optimize=True, disposal=1)
        print(f"{name}: {len(q)} frames, {sum(self.durs)/1000:.1f}s, {(OUT / name).stat().st_size // 1024} KB")


def checklist(t, title, items, cur, help_, replace=True):
    """Draw (or redraw in place) an arrow-key checklist. items = [(checked, label)]."""
    if replace and getattr(t, "_blk", 0):
        del t.lines[-t._blk:]
    rows = ["{b}" + title + "{/}"]
    for i, (on, label) in enumerate(items):
        ptr = "{b}>{/} " if i == cur else "  "
        box = "{lime}[x]{/}" if on else "{dim}[ ]{/}"
        rows.append(f"{ptr}{box} {label}")
    rows.append("{dim}" + help_ + "{/}")
    for r in rows:
        t.lines.append(parse(r))
    t._blk = len(rows)
    t.snap(520, cursor=False)


def setup_demo():
    t = Term("~ — zsh")
    P = "{lime}${/} "
    t.type(P, "npx @noxhsxrk/crewtier init")
    t.out("  {lime}✓{/} app installed → {dim}~/.crewtier/app{/}",
          "  {lime}✓{/} command linked → {dim}~/.local/bin/crewtier{/}", "")
    t.out("{b}Checking which agent CLIs are signed in{/} {dim}(one-word ping each){/}", ms=700)
    t.clear(); t._blk = 0
    H1 = "up/down move · space on/off · s sign in · a all · n none · enter done"
    OK = "{lime}✓ signed in{/}"
    CX = "{amber}✗ auth-required{/}  {dim}(press s to sign in){/}"
    AG = "{red}✗ quota-exhausted{/}  {dim}(press s to sign in){/}"
    title = "Which agents may crewtier use as workers?"
    state = [(True, f"claude    {OK}"), (True, f"codex     {CX}"), (True, f"opencode  {OK}"), (True, f"agy       {AG}")]
    checklist(t, title, state, 0, H1)
    checklist(t, title, state, 1, H1)
    t.out("", "{lime}→ codex{/}: running `codex login` — follow the browser sign-in", ms=500)
    t.out("  {dim}Signed in as you@example.com{/}", ms=900)
    t.out("  {lime}✓{/} codex is ready", "", ms=500)
    t._blk = 0
    state = [(True, f"claude    {OK}"), (True, f"codex     {OK}"), (True, f"opencode  {OK}"), (True, f"agy       {AG}")]
    checklist(t, title, state, 1, H1)
    checklist(t, title, state, 2, H1)
    checklist(t, title, state, 3, H1)
    state[3] = (False, f"agy       {AG}")
    checklist(t, title, state, 3, H1)
    t.out("", "  {lime}✓{/} workers on: claude codex opencode",
          "  {dim}turned off: agy (change later: crewtier enable|disable <agent>){/}", "", ms=900)
    t._blk = 0
    leads = [(True, "claude"), (True, "codex"), (True, "opencode"), (True, "agy")]
    checklist(t, "Install for which lead agents?", leads, 0, "up/down move · space on/off · a all · n none · enter done", replace=False)
    leads[0] = (True, "claude")
    checklist(t, "Install for which lead agents?", leads, 3, "up/down move · space on/off · a all · n none · enter done")
    leads[3] = (False, "agy")
    checklist(t, "Install for which lead agents?", leads, 3, "up/down move · space on/off · a all · n none · enter done")
    t.out("", "{b}scope: user{/}",
          "{b}claude{/}    {lime}✓{/} skill → .claude/skills/crewtier   {lime}✓{/} rules → .claude/CLAUDE.md",
          "{b}codex{/}     {lime}✓{/} skill → .codex/skills/crewtier    {lime}✓{/} rules → .codex/AGENTS.md",
          "{b}opencode{/}  {lime}✓{/} skill via ~/.claude/skills        {lime}✓{/} rules → opencode/AGENTS.md", "", ms=240)
    t.out("Next: open your agent in a repo and ask {lime}\"set up crewtier\"{/}.", ms=200)
    t.pause(2800)
    t.save("setup.gif")


def task_demo():
    t = Term("~/shop-api — your lead agent")
    t.type("{cyan}you ›{/} ", "Rename getUser to fetchUser everywhere", after=500)
    t.out("", "{lime}lead ·{/} small change (~20 lines) → doing it myself", ms=700)
    t.out("{dim}  edited 4 files · pnpm test → {/}{lime}PASS{/}", "", ms=900)
    t.type("{cyan}you ›{/} ", "Add CSV and PDF export to the reports page, with tests", after=600)
    t.out("", "{lime}lead ·{/} big (~400 lines), decided, checkable → one call", ms=700)
    t.out("{dim}$ crewtier do t2-normal --spec .crewtier/specs/export.md --commit \"Add report export\"{/}", ms=1300)
    t.out("{dim}… D1 codex/gpt-6.1-sol still running (3m){/}", ms=1300)
    t.out("{b}D1 {lime}PASS{/}{b} codex/gpt-6.1-sol · 412 lines (5 files) · 4m02s · commit 4e1c2ab{/}", "", ms=900)
    t.out("{lime}lead ·{/} {b}Done.{/} Export is in, tests pass, committed as 4e1c2ab.",
          "        I didn't review the diff: the check passed.", "", ms=400)
    t.out("{dim}$ crewtier session{/}", ms=900)
    t.out("claude session (whole conversation so far)",
          "  cost units: 61204",
          "  lines changed this session: {b}436{/}  (workers: {lime}412{/} in 1 task(s) · lead: 24)",
          "  lead cost per line shipped: {lime}{b}140 units{/}", ms=200)
    t.pause(3400)
    t.save("task.gif")


def picker(t, title, items, cur, help_, replace=True):
    """Single-choice menu (> marks the highlighted row)."""
    if replace and getattr(t, "_blk", 0):
        del t.lines[-t._blk:]
    rows = ["{b}" + title + "{/}"]
    for i, label in enumerate(items):
        rows.append(("{b}> " + label + "{/}") if i == cur else ("  " + label))
    rows.append("{dim}" + help_ + "{/}")
    for r in rows:
        t.lines.append(parse(r))
    t._blk = len(rows)
    t.snap(480, cursor=False)


def menu_demo():
    t = Term("~ — zsh")
    P = "{lime}${/} "
    t.type(P, "crewtier", after=400)
    t.out("", ms=100)
    t._blk = 0
    hub = ["Workers: sign in, turn on or off", "Add agents found on this machine",
           "Routing: which model handles each tier", "Install the skill for more lead agents", "Done"]
    HH = "up/down · enter choose · q quit"
    picker(t, "crewtier setup", hub, 0, HH, replace=False)
    picker(t, "crewtier setup", hub, 1, HH)
    t.out("", ms=200)
    t._blk = 0
    AH = "up/down move · space select · enter add · q back"
    title = "Add which agents as workers? (found on this machine, not set up yet)"
    items = [(False, "Grok             {dim}grok -p \"<prompt>\"{/}"), (False, "Qwen Code        {dim}qwen -p \"<prompt>\"{/}")]
    checklist(t, title, items, 0, AH, replace=False)
    items[0] = (True, items[0][1])
    checklist(t, title, items, 0, AH)
    t.out("  {lime}✓{/} added grok: runs `grok -p <prompt>`", "", ms=500)
    t.out("{b}Next: let your lead agent rebuild the tiers.{/} Paste this into it:", "",
          "  {lime}I just added grok to crewtier. Run `crewtier health --force` and{/}",
          "  {lime}`crewtier agents --models`, then propose a new tier table using only{/}",
          "  {lime}the model names those commands list … wait for my OK before saving.{/}", "", ms=260)
    t.pause(2200)
    t.clear(); t._blk = 0
    picker(t, "crewtier setup", hub, 2, HH, replace=False)
    t.out("", ms=150)
    t._blk = 0
    tiers = ["t1-easy    {dim}codex/gpt-6.1-terra → agy/gemini-3.8-flash-low{/}",
             "t2-normal  {dim}codex/gpt-6.1-terra{/}", "t3-hard    {dim}agy/claude-opus-5-5-high{/}", "← back"]
    picker(t, "Routing: pick a tier to change", tiers, 0, "up/down · enter open · q back", replace=False)
    t.out("", ms=150)
    t._blk = 0
    RH = "space in/out · f first · e effort · m add by hand · enter save"
    rt = "Tier t1-easy: which models, in this order? (tried top to bottom)"
    rows = [[True, "codex     gpt-6.1-terra            {dim}Balanced model for everyday coding{/}"],
            [True, "agy       gemini-3.8-flash-low{/}"],
            [False, "codex     gpt-6-luna               {dim}Fast and affordable model for easier tasks{/}"],
            [False, "grok      grok-4.5-fast            {dim}(added by hand){/}"]]
    def draw(cur, first=False):
        checklist(t, rt, [tuple(r) for r in rows], cur, RH, replace=not first)
    draw(0, first=True)
    draw(1); draw(2)
    rows[2][0] = True; draw(2)
    rows.insert(0, rows.pop(2)); draw(0)          # f = first
    draw(1); draw(2)
    rows[2][0] = False; draw(2)                   # drop gemini
    draw(3)
    rows[3][0] = True; draw(3)
    t.out("  {lime}✓{/} saved t1-easy", "", ms=300)
    t._blk = 0
    tiers[0] = "t1-easy    {dim}codex/gpt-6-luna → codex/gpt-6.1-terra → grok/grok-4.5-fast{/}"
    picker(t, "Routing: pick a tier to change", tiers, 0, "up/down · enter open · q back", replace=False)
    t.pause(2800)
    t.save("menu.gif")


if __name__ == "__main__":
    setup_demo()
    task_demo()
    menu_demo()
