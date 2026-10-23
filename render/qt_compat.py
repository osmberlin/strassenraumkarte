"""
Qt5/Qt6 enum compatibility for the PyQGIS render scripts.

render/xyz_tiles.py uses the Qt5-style unscoped enum names
(QImage.Format_ARGB32_Premultiplied, QPainter.Antialiasing,
QgsMapSettings.Antialiasing, ...). PyQt6 (QGIS 4, e.g. the macOS QGIS.app)
only exposes them on their scoped enum classes (QImage.Format.Format_...,
QPainter.RenderHint.Antialiasing, QgsMapSettings.Flag.Antialiasing).

install() copies the scoped members onto the owning class when the
unscoped name is missing. On Qt5 / QGIS 3 it is a no-op.
"""

from __future__ import annotations

_ALIASES = (
    # (module, class, scoped enum attribute)
    ("qgis.PyQt.QtGui", "QImage", "Format"),
    ("qgis.PyQt.QtGui", "QPainter", "RenderHint"),
    ("qgis.core", "QgsMapSettings", "Flag"),
)

_installed = False


def install() -> int:
    """Alias scoped enum members onto their classes. Returns the number added."""
    global _installed
    if _installed:
        return 0
    import importlib

    added = 0
    for module_name, class_name, enum_name in _ALIASES:
        cls = getattr(importlib.import_module(module_name), class_name)
        enum_cls = getattr(cls, enum_name, None)
        if enum_cls is None:
            continue
        members = getattr(enum_cls, "__members__", None)
        if not members:
            continue
        for name, value in members.items():
            if not hasattr(cls, name):
                try:
                    setattr(cls, name, value)
                    added += 1
                except (AttributeError, TypeError):
                    pass
    _installed = True
    return added
