# Source this file to use the macOS QGIS.app Python (PyQGIS) for tile rendering.
#
#   source render/qgis_env.sh
#   ./render/render_tiles.sh …
#
# Override the app bundle with QGIS_APP if needed:
#   export QGIS_APP=/Applications/QGIS-final-4_0_2.app
#

# Avoid re-sourcing stacking PATH repeatedly in the same shell.
if [[ -n "${_STRASSENRAUMKARTE_QGIS_ENV:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_STRASSENRAUMKARTE_QGIS_ENV=1

QGIS_APP="${QGIS_APP:-/Applications/QGIS-final-4_0_2.app}"

if [[ ! -d "$QGIS_APP" ]]; then
  # Host without this QGIS.app (e.g. tools container): leave PYTHON unset for caller fallback.
  return 0 2>/dev/null || true
fi

export QGIS_PREFIX_PATH="${QGIS_PREFIX_PATH:-$QGIS_APP/Contents/MacOS}"
export PATH="$QGIS_PREFIX_PATH:$PATH"

# Bundled wrapper sets PYTHONHOME so the relocatable interpreter finds stdlib + qgis.
if [[ -x "$QGIS_PREFIX_PATH/python" ]]; then
  export PYTHON="${PYTHON:-$QGIS_PREFIX_PATH/python}"
fi

# Headless metatile rendering (also set in render_tiles.sh as a fallback).
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

# Quiet PROJ/GDAL lookup noise when running outside the GUI.
if [[ -d "$QGIS_APP/Contents/Resources/qgis/proj" ]]; then
  export PROJ_DATA="${PROJ_DATA:-$QGIS_APP/Contents/Resources/qgis/proj}"
  export PROJ_LIB="${PROJ_LIB:-$PROJ_DATA}"
fi
if [[ -d "$QGIS_APP/Contents/Resources/qgis/gdal" ]]; then
  export GDAL_DATA="${GDAL_DATA:-$QGIS_APP/Contents/Resources/qgis/gdal}"
fi
