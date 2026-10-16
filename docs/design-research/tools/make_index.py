#!/usr/bin/env python3
"""Write docs/design-research/index.html: a static overview of both style explorations.

    python3 docs/design-research/tools/make_index.py

Scans the exploration folders (current images, legends, map sheets, showcases, steps/*) and
writes one self-contained page with relative links, so it works when opened from disk
(file://) and on GitHub Pages alike. Run it again after saving a step.
"""
import html
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.abspath(os.path.join(HERE, ".."))
EXPLORATIONS = [
    ("01-landscape-architecture", "Landschaftsarchitektur", "la"),
    ("02-fantasy-ink-map", "Fantasy-Tuschekarte", "ink"),
]
# order and captions of the "current state" images; anything else at top level is appended
CURRENT = [
    ("current.jpg", "Szenen A–D"),
    ("current-ef.jpg", "Szenen E–F"),
    ("legend.jpg", "Legende"),
    ("showcase-z17.jpg", "Übersicht z17"),
    ("showcase-z18.jpg", "Übersicht z18"),
]


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", t)  # drop embedded images
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)  # links → text (relative paths would break)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\w*])_(.+?)_(?!\w)", r"<em>\1</em>", t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


def markdown(md):
    """Tiny Markdown subset for step READMEs: paragraphs, bullet lists, bold, code. Title line dropped."""
    out, para, items = [], [], []

    def flush():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in md.splitlines():
        s = line.strip()
        if s.startswith("#") or s.startswith("|") or s == "---":
            flush()
            if s.startswith("##"):
                out.append(f"<h4>{inline(s.lstrip('#').strip())}</h4>")
            continue
        if not s:
            flush()
        elif s.startswith(("- ", "* ")):
            if para:
                flush()
            items.append(s[2:])
        elif items and line.startswith("  "):
            items[-1] += " " + s
        else:
            if items:
                flush()
            para.append(s)
    flush()
    return "\n".join(out)


def title_of(md, fallback):
    for line in md.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def mission(readme):
    m = re.search(r"^> \*\*(.+?)\*\*", readme, re.M)
    return m.group(1) if m else ""


def figure(src, caption, group):
    return (f'<figure><a href="{src}" data-group="{group}" data-caption="{html.escape(caption)}">'
            f'<img src="{src}" loading="lazy" alt="{html.escape(caption)}"></a>'
            f"<figcaption>{html.escape(caption)}</figcaption></figure>")


def section(folder, name, key):
    root = os.path.join(BASE, folder)
    readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
    files = sorted(f for f in os.listdir(root) if f.lower().endswith((".jpg", ".png")))
    known = [f for f, _ in CURRENT]
    current = [(f, c) for f, c in CURRENT if f in files]
    sheets = [(f, "Kartenblatt " + f[len("map-sheet-"):-4].replace("-", " "))
              for f in files if f.startswith("map-sheet")]
    other = [(f, f[:-4]) for f in files if f not in known and not f.startswith("map-sheet")]
    parts = [f'<section id="{key}"><h2>{html.escape(name)} <small><code>--layers {key}</code></small></h2>']
    if mission(readme):
        parts.append(f'<p class="mission">{inline(mission(readme))}</p>')
    parts.append(f'<p class="links"><a href="{folder}/README.md">README</a> · '
                 f'<a href="{folder}/research-notes.md">Recherche</a> · <a href="{folder}/steps/">Schritte</a> · '
                 f'<a href="{folder}/mockups/">Mockups</a></p>')
    parts.append("<h3>Aktueller Stand</h3><div class='grid'>")
    parts += [figure(f"{folder}/{f}", c, key + "-current") for f, c in current + other]
    parts.append("</div>")
    if sheets:
        parts.append("<h3>Kartenblätter</h3><div class='grid'>")
        parts += [figure(f"{folder}/{f}", c, key + "-sheets") for f, c in sheets]
        parts.append("</div>")
    steps_dir = os.path.join(root, "steps")
    steps = sorted((d for d in os.listdir(steps_dir) if os.path.isdir(os.path.join(steps_dir, d))), reverse=True) \
        if os.path.isdir(steps_dir) else []
    parts.append(f"<h3>Verlauf <small>{len(steps)} Schritte, neueste zuerst</small></h3>")
    for i, step in enumerate(steps):
        sd = os.path.join(steps_dir, step)
        md_path = os.path.join(sd, "README.md")
        md = open(md_path, encoding="utf-8").read() if os.path.exists(md_path) else ""
        imgs = sorted((f for f in os.listdir(sd) if f.lower().endswith((".jpg", ".png"))),
                      key=lambda f: (f != "before-after.jpg", f != "sheet.jpg", f != "detail.jpg", f))
        rel = f"{folder}/steps/{step}"
        parts.append(f'<details class="step"{" open" if i < 3 else ""} id="{key}-{step}">'
                     f"<summary>{html.escape(title_of(md, step))}</summary><div class='step-body'>"
                     f"<div class='text'>{markdown(md)}<p class='links'><a href='{rel}/README.md'>README</a></p></div>"
                     "<div class='thumbs'>")
        parts += [figure(f"{rel}/{f}", f"{step} · {f}", f"{key}-{step}") for f in imgs]
        parts.append("</div></div></details>")
    parts.append("</section>")
    return "\n".join(parts)


def main():
    comp = []
    for folder, name, key in EXPLORATIONS:
        if os.path.exists(os.path.join(BASE, folder, "current.jpg")):
            comp.append(figure(f"{folder}/current.jpg", name, "compare"))
    scenes = sorted(f for f in os.listdir(os.path.join(BASE, "scenes")) if f.endswith(".jpg"))
    body = [
        "<header><h1>Design-Explorationen · Straßenraumkarte</h1><nav>",
        " · ".join(f'<a href="#{k}">{html.escape(n)}</a>' for _, n, k in EXPLORATIONS),
        ' · <a href="#scenes">Testszenen</a> · <a href="README.md">README</a> · '
        '<a href="NIGHT-2026-10-15.md">Nachtbericht</a></nav></header>',
        "<section><h2>Nebeneinander</h2><div class='grid two'>", *comp, "</div></section>",
        *(section(*e) for e in EXPLORATIONS),
        '<section id="scenes"><h2>Testszenen <small>heute (QGIS) und Rust-Basis</small></h2><div class="grid">',
        *(figure(f"scenes/{f}", f[:-4], "scenes") for f in scenes),
        "</div></section>",
        "<footer>Erzeugt von <code>tools/make_index.py</code> — nach jedem gespeicherten Schritt neu ausführen. "
        "Interaktiv vergleichen: <code>tools/serve_viewer.sh</code>.</footer>",
    ]
    page = TEMPLATE.replace("{{BODY}}", "\n".join(body))
    out = os.path.join(BASE, "index.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    print(out)


TEMPLATE = """<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Design-Explorationen</title>
<style>
  :root { --bg: #f6f5f1; --fg: #2b2a26; --muted: #77746b; --line: #dad7cd; --card: #fff; --accent: #b4532a; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #1d1c1a; --fg: #e8e6df; --muted: #a39f94; --line: #3b3935; --card: #262522; --accent: #e08a5f; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, sans-serif; }
  header { position: sticky; top: 0; z-index: 5; background: var(--bg); border-bottom: 1px solid var(--line); padding: 10px 16px; }
  header h1 { margin: 0; font-size: 18px; } nav { font-size: 14px; }
  a { color: var(--accent); }
  section { max-width: 1400px; margin: 0 auto; padding: 8px 16px 24px; }
  h2 { margin: 28px 0 4px; } h2 small, h3 small { color: var(--muted); font-weight: 400; font-size: 14px; }
  h3 { margin: 22px 0 8px; } h4 { margin: 10px 0 2px; font-size: 14px; }
  .mission { font-size: 17px; max-width: 70ch; } .links { color: var(--muted); font-size: 13px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; }
  .grid.two { grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); }
  figure { margin: 0; background: var(--card); border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  figure img { display: block; width: 100%; height: auto; aspect-ratio: auto; background: #ddd; }
  figcaption { padding: 4px 8px; font-size: 13px; color: var(--muted); }
  .grid figure img { height: 260px; object-fit: cover; }
  .grid.two figure img { height: auto; }
  details.step { border-top: 1px solid var(--line); padding: 6px 0; }
  details.step summary { cursor: pointer; font-weight: 600; }
  .step-body { display: grid; grid-template-columns: minmax(260px, 1fr) 2fr; gap: 16px; margin-top: 8px; }
  .step-body .text { font-size: 14px; } .step-body ul { padding-left: 18px; margin: 4px 0; }
  .thumbs { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 8px; align-content: start; }
  .thumbs img { height: 170px; object-fit: cover; }
  code { font-size: 90%; background: rgba(127,127,127,.15); padding: 0 3px; border-radius: 3px; }
  footer { max-width: 1400px; margin: 0 auto; padding: 16px; color: var(--muted); font-size: 13px; }
  @media (max-width: 760px) { .step-body { grid-template-columns: 1fr; } }
  #lb { position: fixed; inset: 0; z-index: 10; background: rgba(0,0,0,.88); display: none; flex-direction: column; }
  #lb.on { display: flex; }
  #lb .wrap { flex: 1; overflow: auto; display: flex; align-items: center; justify-content: center; }
  #lb img { max-width: 100%; max-height: 100%; cursor: zoom-in; }
  #lb.full img { max-width: none; max-height: none; cursor: zoom-out; }
  #lb .bar { color: #eee; padding: 8px 16px; font-size: 14px; display: flex; gap: 16px; }
  #lb .bar span { flex: 1; } #lb button { font: inherit; background: none; color: #eee; border: 1px solid #777; border-radius: 4px; cursor: pointer; }
</style>
</head>
<body>
{{BODY}}
<div id="lb"><div class="bar"><span></span><button data-d="-1">←</button><button data-d="1">→</button><button data-x>✕</button></div>
<div class="wrap"><img alt=""></div></div>
<script>
  // lightbox: click opens, ←/→ walks the group (one step or one image grid), click image = 1:1, Esc closes
  const lb = document.getElementById('lb'), img = lb.querySelector('img'), cap = lb.querySelector('.bar span');
  let group = [], idx = 0;
  const show = () => { const a = group[idx]; img.src = a.getAttribute('href'); cap.textContent = `${a.dataset.caption}  (${idx + 1}/${group.length})`; };
  document.addEventListener('click', e => {
    const a = e.target.closest('a[data-group]');
    if (!a || e.metaKey || e.ctrlKey) return;
    e.preventDefault();
    group = [...document.querySelectorAll(`a[data-group="${a.dataset.group}"]`)];
    idx = group.indexOf(a); lb.classList.add('on'); lb.classList.remove('full'); show();
  });
  const go = d => { idx = (idx + d + group.length) % group.length; show(); };
  lb.querySelectorAll('[data-d]').forEach(b => b.onclick = () => go(+b.dataset.d));
  lb.querySelector('[data-x]').onclick = () => lb.classList.remove('on');
  img.onclick = () => lb.classList.toggle('full');
  document.addEventListener('keydown', e => {
    if (!lb.classList.contains('on')) return;
    if (e.key === 'Escape') lb.classList.remove('on');
    if (e.key === 'ArrowRight') go(1);
    if (e.key === 'ArrowLeft') go(-1);
  });
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
