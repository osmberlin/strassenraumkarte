#!/usr/bin/env python3
"""Dump a machine-readable style inventory / IR from strassenraumkarte.qgz.

Requires macOS QGIS.app PyQGIS (same as tile rendering):

  source render/qgis_env.sh
  python3 style/scripts/dump-style.py
  # optional:
  python3 style/scripts/dump-style.py --project style/strassenraumkarte.qgz \\
    --out-dir style/generated --layer highway_area

Writes (under --out-dir, default style/generated/):

  style-inventory.md          — authoritative layer / symbol / effect / label counts
  expression-surface.json     — distinct expression functions + @variables with counts
  style-ir.json               — trimmed IR for --layer (default: highway_area only)

Full-project IR is intentionally not the default (huge); pass --all-layers for every
map layer (still skips writing a second IR file unless --ir-all).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Optional

# Headless Qt before QGIS imports (mirrors render/xyz_tiles.py).
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from qgis.core import (  # noqa: E402
    QgsApplication,
    QgsCategorizedSymbolRenderer,
    QgsEffectStack,
    QgsNullSymbolRenderer,
    QgsProject,
    QgsRuleBasedRenderer,
    QgsSingleSymbolRenderer,
    QgsSymbol,
    QgsSymbolLayer,
    QgsVectorLayer,
)

_SYMBOL_PROP_DEFS = None


def symbol_prop_name(key: int) -> str:
    global _SYMBOL_PROP_DEFS
    if _SYMBOL_PROP_DEFS is None:
        _SYMBOL_PROP_DEFS = QgsSymbolLayer.propertyDefinitions()
    prop_def = _SYMBOL_PROP_DEFS.get(key)
    if prop_def is not None and hasattr(prop_def, "name"):
        return prop_def.name()
    return str(key)

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROJECT = ROOT / "style" / "strassenraumkarte.qgz"
DEFAULT_OUT = ROOT / "style" / "generated"

# QgsExpression token-ish extractors (good enough for inventory; not a full parser).
RE_FUNC = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(")
RE_VAR = re.compile(r"@([a-zA-Z_][a-zA-Z0-9_]*)")
# Common keywords that look like functions in regex but are not expression fns.
FUNC_STOP = {
    "if",
    "case",
    "when",
    "then",
    "else",
    "end",
    "and",
    "or",
    "not",
    "in",
    "is",
    "null",
    "true",
    "false",
}


def init_qgis() -> QgsApplication:
    prefix = os.environ.get("QGIS_PREFIX_PATH", "/usr")
    QgsApplication.setPrefixPath(prefix, True)
    plugin_path = os.environ.get("QGIS_PLUGIN_PATH")
    if plugin_path:
        QgsApplication.setPluginPath(plugin_path)
    pkg_data = os.environ.get("QGIS_PKG_DATA_PATH")
    if pkg_data:
        QgsApplication.setPkgDataPath(pkg_data)
    app = QgsApplication([], False)
    app.initQgis()
    return app


def blend_mode_name(mode) -> str:
    # QPainter::CompositionMode — may arrive as int or enum-like.
    try:
        mode_i = int(mode)
    except (TypeError, ValueError):
        mode_i = int(getattr(mode, "value", mode))
    known = {
        0: "SourceOver",
        1: "DestinationOver",
        2: "Clear",
        3: "Source",
        4: "Destination",
        5: "SourceIn",
        6: "DestinationIn",
        7: "SourceOut",
        8: "DestinationOut",
        9: "SourceAtop",
        10: "DestinationAtop",
        11: "Xor",
        12: "Plus",
        13: "Multiply",
        14: "Screen",
        15: "Overlay",
        16: "Darken",
        17: "Lighten",
        18: "ColorDodge",
        19: "ColorBurn",
        20: "HardLight",
        21: "SoftLight",
        22: "Difference",
        23: "Exclusion",
    }
    return known.get(mode_i, f"mode_{mode_i}")


def blend_mode_int(mode) -> int:
    try:
        return int(mode)
    except (TypeError, ValueError):
        return int(getattr(mode, "value", 0))


def datasource_bits(layer: QgsVectorLayer) -> dict[str, Any]:
    ds = layer.dataProvider().dataSourceUri() if layer.dataProvider() else layer.source()
    table = None
    sql = None
    # postgres uri: ... table="schema"."table" ... sql=...
    m = re.search(r'table="([^"]+)"\."([^"]+)"', ds) or re.search(
        r"table=([^\s]+)", ds
    )
    if m:
        table = ".".join(m.groups()) if m.lastindex and m.lastindex >= 2 else m.group(1)
    msql = re.search(r"\bsql=(.*)$", ds)
    if msql:
        sql = msql.group(1).strip()
    return {"datasource": ds, "table": table, "sql_filter": sql or None}


def collect_ddp(symbol_layer) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    props = symbol_layer.dataDefinedProperties()
    for key in props.propertyKeys():
        if not props.isActive(key):
            continue
        prop = props.property(key)
        expr = prop.asExpression() if prop else ""
        out.append(
            {
                "property_key": int(key),
                "property_name": symbol_prop_name(int(key)),
                "expression": expr,
            }
        )
    return out


def collect_effects(symbol_layer) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not symbol_layer.paintEffect():
        return out
    effect = symbol_layer.paintEffect()
    stack: Optional[QgsEffectStack]
    if isinstance(effect, QgsEffectStack):
        stack = effect
    else:
        # Single effect — wrap as one entry.
        props = effect.properties() if hasattr(effect, "properties") else {}
        out.append(
            {
                "type": effect.type() if hasattr(effect, "type") else type(effect).__name__,
                "enabled": bool(effect.enabled()) if hasattr(effect, "enabled") else True,
                "properties": dict(props) if props else {},
            }
        )
        return out

    for i, eff in enumerate(stack.effectList()):
        if eff is None:
            continue
        props = eff.properties() if hasattr(eff, "properties") else {}
        out.append(
            {
                "index": i,
                "type": eff.type() if hasattr(eff, "type") else type(eff).__name__,
                "enabled": bool(eff.enabled()) if hasattr(eff, "enabled") else True,
                "properties": dict(props) if props else {},
            }
        )
    return out


def dump_symbol(symbol: Optional[QgsSymbol], *, _depth: int = 0) -> Optional[dict[str, Any]]:
    if symbol is None:
        return None
    layers = []
    for i in range(symbol.symbolLayerCount()):
        sl = symbol.symbolLayer(i)
        if sl is None:
            continue
        entry: dict[str, Any] = {
            "index": i,
            "class": type(sl).__name__,
            "enabled": bool(sl.enabled()) if hasattr(sl, "enabled") else True,
            "properties": dict(sl.properties()) if hasattr(sl, "properties") else {},
            "data_defined": collect_ddp(sl),
            "effects": collect_effects(sl),
        }
        # Nested marker/fill/line symbols (MarkerLine, CentroidFill, …).
        if hasattr(sl, "subSymbol") and sl.subSymbol() is not None and _depth < 8:
            entry["sub_symbol"] = dump_symbol(sl.subSymbol(), _depth=_depth + 1)
        layers.append(entry)
    return {
        "type": symbol.type().name if hasattr(symbol.type(), "name") else str(symbol.type()),
        "opacity": float(symbol.opacity()) if hasattr(symbol, "opacity") else 1.0,
        "symbol_layers": layers,
    }


def walk_rules(node, depth: int = 0) -> list[dict[str, Any]]:
    """Flatten QgsRuleBasedRenderer rule tree."""
    rows: list[dict[str, Any]] = []
    children = node.children() if hasattr(node, "children") else []
    for child in children:
        filt = child.filterExpression() if hasattr(child, "filterExpression") else ""
        label = child.label() if hasattr(child, "label") else ""
        active = bool(child.active()) if hasattr(child, "active") else True
        scale_min = child.minimumScale() if hasattr(child, "minimumScale") else 0
        scale_max = child.maximumScale() if hasattr(child, "maximumScale") else 0
        row: dict[str, Any] = {
            "depth": depth,
            "label": label,
            "filter": filt,
            "active": active,
            "scalemindenom": scale_min,
            "scalemaxdenom": scale_max,
            "symbol": dump_symbol(child.symbol()) if child.symbol() else None,
        }
        rows.append(row)
        rows.extend(walk_rules(child, depth + 1))
    return rows


def dump_renderer(layer: QgsVectorLayer) -> dict[str, Any]:
    r = layer.renderer()
    if r is None:
        return {"type": "none"}
    rtype = type(r).__name__
    base: dict[str, Any] = {"type": rtype, "class": rtype}

    if isinstance(r, QgsRuleBasedRenderer):
        root = r.rootRule()
        base["rules"] = walk_rules(root)
        base["rule_count"] = len(base["rules"])
    elif isinstance(r, QgsSingleSymbolRenderer):
        base["symbol"] = dump_symbol(r.symbol())
    elif isinstance(r, QgsCategorizedSymbolRenderer):
        cats = []
        for cat in r.categories():
            cats.append(
                {
                    "value": str(cat.value()),
                    "label": cat.label(),
                    "symbol": dump_symbol(cat.symbol()),
                }
            )
        base["categories"] = cats
        base["category_count"] = len(cats)
        base["class_attribute"] = r.classAttribute()
    elif isinstance(r, QgsNullSymbolRenderer):
        base["symbol"] = None
    else:
        # Best-effort: some renderers expose symbol() / symbols().
        if hasattr(r, "symbol") and callable(r.symbol):
            try:
                base["symbol"] = dump_symbol(r.symbol())
            except Exception:
                pass
    return base


def labeling_info(layer: QgsVectorLayer) -> dict[str, Any]:
    enabled = bool(layer.labelsEnabled()) if hasattr(layer, "labelsEnabled") else False
    info: dict[str, Any] = {"enabled": enabled}
    if not enabled:
        return info
    labeling = layer.labeling() if hasattr(layer, "labeling") else None
    if labeling is None:
        return info
    info["labeling_type"] = type(labeling).__name__
    # Rule-based vs simple — record rule count when present.
    if hasattr(labeling, "rootRule"):
        def count_rules(node) -> int:
            n = 0
            for c in node.children():
                n += 1 + count_rules(c)
            return n

        info["label_rule_count"] = count_rules(labeling.rootRule())
    return info


def iter_expressions_from_ir_layer(layer_ir: dict[str, Any]) -> Iterable[str]:
    def from_symbol(sym: Optional[dict]) -> Iterable[str]:
        if not sym:
            return
        for sl in sym.get("symbol_layers") or []:
            for dd in sl.get("data_defined") or []:
                expr = dd.get("expression") or ""
                if expr.strip():
                    yield expr
            for eff in sl.get("effects") or []:
                for v in (eff.get("properties") or {}).values():
                    if isinstance(v, str) and ("@" in v or "(" in v):
                        yield v
            if sl.get("sub_symbol"):
                yield from from_symbol(sl["sub_symbol"])

    rend = layer_ir.get("renderer") or {}
    if rend.get("symbol"):
        yield from from_symbol(rend["symbol"])
    for rule in rend.get("rules") or []:
        filt = rule.get("filter") or ""
        if filt.strip():
            yield filt
        yield from from_symbol(rule.get("symbol"))
    for cat in rend.get("categories") or []:
        yield from from_symbol(cat.get("symbol"))


def harvest_expressions(layer: QgsVectorLayer) -> list[str]:
    """Collect expression strings without building full IR (inventory path)."""
    exprs: list[str] = []
    r = layer.renderer()
    if r is None:
        return exprs

    def from_symbol(symbol: Optional[QgsSymbol], depth: int = 0) -> None:
        if symbol is None or depth > 8:
            return
        for i in range(symbol.symbolLayerCount()):
            sl = symbol.symbolLayer(i)
            if sl is None:
                continue
            for dd in collect_ddp(sl):
                if dd["expression"].strip():
                    exprs.append(dd["expression"])
            if hasattr(sl, "subSymbol") and sl.subSymbol() is not None:
                from_symbol(sl.subSymbol(), depth + 1)

    if isinstance(r, QgsRuleBasedRenderer):

        def walk(node) -> None:
            for child in node.children():
                filt = child.filterExpression() or ""
                if filt.strip():
                    exprs.append(filt)
                from_symbol(child.symbol())
                walk(child)

        walk(r.rootRule())
    elif isinstance(r, QgsSingleSymbolRenderer):
        from_symbol(r.symbol())
    elif isinstance(r, QgsCategorizedSymbolRenderer):
        for cat in r.categories():
            from_symbol(cat.symbol())
    return exprs


def count_symbol_layers(layer: QgsVectorLayer) -> tuple[Counter, Counter, int]:
    """Return (symbol_class_counts, effect_type_counts, active_ddp_count)."""
    sym_c: Counter = Counter()
    eff_c: Counter = Counter()
    ddp_n = 0

    def from_symbol(symbol: Optional[QgsSymbol], depth: int = 0) -> None:
        nonlocal ddp_n
        if symbol is None or depth > 8:
            return
        for i in range(symbol.symbolLayerCount()):
            sl = symbol.symbolLayer(i)
            if sl is None:
                continue
            sym_c[type(sl).__name__] += 1
            ddp_n += len(collect_ddp(sl))
            for eff in collect_effects(sl):
                if eff.get("enabled", True):
                    eff_c[str(eff.get("type"))] += 1
            if hasattr(sl, "subSymbol") and sl.subSymbol() is not None:
                from_symbol(sl.subSymbol(), depth + 1)

    r = layer.renderer()
    if r is None:
        return sym_c, eff_c, ddp_n
    if isinstance(r, QgsRuleBasedRenderer):

        def walk(node) -> None:
            for child in node.children():
                from_symbol(child.symbol())
                walk(child)

        walk(r.rootRule())
    elif isinstance(r, QgsSingleSymbolRenderer):
        from_symbol(r.symbol())
    elif isinstance(r, QgsCategorizedSymbolRenderer):
        for cat in r.categories():
            from_symbol(cat.symbol())
    return sym_c, eff_c, ddp_n


def analyze_expressions(exprs: Iterable[str]) -> dict[str, Any]:
    func_c: Counter = Counter()
    var_c: Counter = Counter()
    n = 0
    for expr in exprs:
        n += 1
        for fn in RE_FUNC.findall(expr):
            if fn.lower() in FUNC_STOP:
                continue
            func_c[fn] += 1
        for var in RE_VAR.findall(expr):
            var_c[f"@{var}"] += 1
    return {
        "expression_count": n,
        "functions": dict(func_c.most_common()),
        "variables": dict(var_c.most_common()),
        "note": "Functions/vars extracted with regex over PyQGIS expression strings; "
        "not a full QgsExpression AST. 'if'/'case' keywords excluded from function counts.",
    }


def dump_layer_ir(layer: QgsVectorLayer) -> dict[str, Any]:
    bits = datasource_bits(layer)
    opacity = float(layer.opacity()) if hasattr(layer, "opacity") else 1.0
    blend = blend_mode_int(layer.blendMode()) if hasattr(layer, "blendMode") else 0
    order_by = None
    if hasattr(layer, "renderer") and layer.renderer() is not None:
        # Feature order-by is a layer-level setting in recent QGIS via renderer / layer.
        pass
    if hasattr(layer, "customProperty"):
        # building_parts_dissolved_height uses enableorderby in XML; expose custom props lightly.
        pass

    # Scale visibility
    scale_min = layer.minimumScale() if hasattr(layer, "minimumScale") else 0
    scale_max = layer.maximumScale() if hasattr(layer, "maximumScale") else 0

    symbol_levels = False
    r = layer.renderer()
    if r is not None and hasattr(r, "usingSymbolLevels"):
        symbol_levels = bool(r.usingSymbolLevels())

    return {
        "id": layer.id(),
        "name": layer.name(),
        "geometry_type": layer.geometryType().name
        if hasattr(layer.geometryType(), "name")
        else str(layer.geometryType()),
        "crs": layer.crs().authid() if layer.crs() else None,
        "opacity": opacity,
        "blend_mode": blend,
        "blend_mode_name": blend_mode_name(blend),
        "scale_visibility": {
            "scalemindenom": scale_min,
            "scalemaxdenom": scale_max,
            "hasScaleBasedVisibility": bool(layer.hasScaleBasedVisibility())
            if hasattr(layer, "hasScaleBasedVisibility")
            else False,
        },
        "symbol_levels": symbol_levels,
        "order_by": order_by,
        "labeling": labeling_info(layer),
        **bits,
        "renderer": dump_renderer(layer),
    }


def write_inventory_md(
    path: Path,
    *,
    project_path: Path,
    maplayer_count: int,
    unique_names: Counter,
    renderer_types: Counter,
    sym_counts: Counter,
    eff_counts: Counter,
    labeling_enabled: int,
    labeling_unique_names: int,
    active_ddp: int,
    non_default_opacity: int,
    opacity_unique_names: int,
    blend_modes: Counter,
    elapsed_s: float,
) -> None:
    lines = [
        "# Style inventory (PyQGIS)",
        "",
        f"Source: `{project_path.relative_to(ROOT) if project_path.is_relative_to(ROOT) else project_path}`  ",
        f"Generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}  ",
        f"Dump wall clock: {elapsed_s:.1f}s  ",
        "",
        "Authoritative counts from a loaded `QgsProject` (not raw XML). "
        "Resolves the data-defined-property / opacity disagreements between XML parses.",
        "",
        "Counts walk nested `subSymbol()` trees (MarkerLine / CentroidFill / …). "
        "Effect types are `QgsPaintEffect.type()` strings; `drawSource` is the stack’s "
        "pass-through paint and is listed separately from shadows/glows.",
        "",
        "## Totals",
        "",
        "| Metric | Count |",
        "| --- | ---: |",
        f"| `maplayer` entries | {maplayer_count} |",
        f"| Unique layer names | {len(unique_names)} |",
        f"| Layers with labeling enabled (maplayer entries) | {labeling_enabled} |",
        f"| Unique names with labeling enabled | {labeling_unique_names} |",
        f"| Active data-defined properties | {active_ddp} |",
        f"| Layers with opacity ≠ 1.0 (maplayer entries) | {non_default_opacity} |",
        f"| Unique names with opacity ≠ 1.0 | {opacity_unique_names} |",
        "",
        "## Renderer types",
        "",
        "| Renderer | Count |",
        "| --- | ---: |",
    ]
    for k, v in renderer_types.most_common():
        lines.append(f"| {k} | {v} |")
    lines += [
        "",
        "## Symbol layer classes",
        "",
        "| Class | Count |",
        "| --- | ---: |",
    ]
    for k, v in sym_counts.most_common():
        lines.append(f"| {k} | {v} |")
    lines += [
        "",
        "## Enabled paint effects (by type string)",
        "",
        "| Effect type | Count |",
        "| --- | ---: |",
    ]
    if eff_counts:
        for k, v in eff_counts.most_common():
            lines.append(f"| {k} | {v} |")
    else:
        lines.append("| *(none)* | 0 |")
    shadow_glow = sum(
        v
        for k, v in eff_counts.items()
        if k in {"dropShadow", "innerShadow", "outerGlow", "innerGlow"}
    )
    lines += [
        "",
        f"**Enabled effects total:** {sum(eff_counts.values())}  ",
        f"**Shadows/glows only (excl. drawSource):** {shadow_glow}",
        "",
        "## Blend modes (non-SourceOver)",
        "",
        "| Mode | Count |",
        "| --- | ---: |",
    ]
    non_so = {k: v for k, v in blend_modes.items() if k != "SourceOver"}
    if non_so:
        for k, v in sorted(non_so.items(), key=lambda kv: (-kv[1], kv[0])):
            lines.append(f"| {k} | {v} |")
    else:
        lines.append("| *(none)* | 0 |")
    lines += [
        "",
        "## Unique layer names (alphabetical)",
        "",
    ]
    for name, n in sorted(unique_names.items(), key=lambda kv: kv[0].lower()):
        lines.append(f"- `{name}` ×{n}")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", type=Path, default=DEFAULT_PROJECT)
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    p.add_argument(
        "--layer",
        default="highway_area",
        help="Layer name for trimmed style-ir.json (default: highway_area). "
        "Use empty string with --ir-all for every layer.",
    )
    p.add_argument(
        "--ir-all",
        action="store_true",
        help="Write full style-ir.json for all map layers (large).",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    project_path = args.project.resolve()
    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if not project_path.is_file():
        print(f"ERROR: project not found: {project_path}", file=sys.stderr)
        return 1

    t0 = time.time()
    app = init_qgis()
    try:
        project = QgsProject.instance()
        print(f"Reading {project_path} …", flush=True)
        if not project.read(str(project_path)):
            print("ERROR: QgsProject.read failed", file=sys.stderr)
            return 1
        print(f"Loaded in {time.time() - t0:.1f}s", flush=True)

        layers = list(project.mapLayers().values())
        maplayer_count = len(layers)
        unique_names: Counter = Counter()
        renderer_types: Counter = Counter()
        sym_counts: Counter = Counter()
        eff_counts: Counter = Counter()
        blend_modes: Counter = Counter()
        labeling_enabled = 0
        labeling_names: set[str] = set()
        active_ddp = 0
        non_default_opacity = 0
        opacity_names: set[str] = set()
        all_exprs: list[str] = []
        ir_layers: list[dict[str, Any]] = []
        target_name = (args.layer or "").strip()

        for layer in layers:
            if not isinstance(layer, QgsVectorLayer):
                # Still count name for inventory completeness.
                unique_names[layer.name()] += 1
                continue
            unique_names[layer.name()] += 1
            r = layer.renderer()
            renderer_types[type(r).__name__ if r else "none"] += 1
            sc, ec, ddp_n = count_symbol_layers(layer)
            sym_counts.update(sc)
            eff_counts.update(ec)
            active_ddp += ddp_n
            if hasattr(layer, "labelsEnabled") and layer.labelsEnabled():
                labeling_enabled += 1
                labeling_names.add(layer.name())
            opacity = float(layer.opacity()) if hasattr(layer, "opacity") else 1.0
            if abs(opacity - 1.0) > 1e-9:
                non_default_opacity += 1
                opacity_names.add(layer.name())
            blend = blend_mode_name(
                layer.blendMode() if hasattr(layer, "blendMode") else 0
            )
            blend_modes[blend] += 1
            all_exprs.extend(harvest_expressions(layer))

            want_ir = args.ir_all or (target_name and layer.name() == target_name)
            if want_ir:
                ir_layers.append(dump_layer_ir(layer))

        elapsed = time.time() - t0
        inv_path = out_dir / "style-inventory.md"
        write_inventory_md(
            inv_path,
            project_path=project_path,
            maplayer_count=maplayer_count,
            unique_names=unique_names,
            renderer_types=renderer_types,
            sym_counts=sym_counts,
            eff_counts=eff_counts,
            labeling_enabled=labeling_enabled,
            labeling_unique_names=len(labeling_names),
            active_ddp=active_ddp,
            non_default_opacity=non_default_opacity,
            opacity_unique_names=len(opacity_names),
            blend_modes=blend_modes,
            elapsed_s=elapsed,
        )
        print(f"Wrote {inv_path}")

        expr_surface = analyze_expressions(all_exprs)
        expr_path = out_dir / "expression-surface.json"
        expr_path.write_text(json.dumps(expr_surface, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote {expr_path}")

        ir_doc = {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "project": str(project_path.relative_to(ROOT))
            if project_path.is_relative_to(ROOT)
            else str(project_path),
            "scope": "all" if args.ir_all else f"layer:{target_name}",
            "layer_count": len(ir_layers),
            "layers": ir_layers,
        }
        ir_path = out_dir / "style-ir.json"
        ir_path.write_text(json.dumps(ir_doc, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote {ir_path} ({len(ir_layers)} layer entries, scope={ir_doc['scope']})")
        print(
            f"Done in {elapsed:.1f}s — maplayers={maplayer_count} "
            f"unique_names={len(unique_names)} labeling={labeling_enabled} "
            f"ddp={active_ddp} effects={sum(eff_counts.values())}"
        )
        return 0
    finally:
        app.exitQgis()


if __name__ == "__main__":
    raise SystemExit(main())
