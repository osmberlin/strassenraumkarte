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

# Binaries (python wrapper, qgis_process) live under Contents/MacOS.
export PATH="$QGIS_APP/Contents/MacOS:$PATH"
if [[ -x "$QGIS_APP/Contents/MacOS/python" ]]; then
  export PYTHON="${PYTHON:-$QGIS_APP/Contents/MacOS/python}"
fi

# QgsApplication prefix for this QGIS 4 macOS build is the .app bundle root
# (not Contents/MacOS). Wrong prefix → postgres provider missing → 0 valid layers.
# Always derive from QGIS_APP (do not keep a stale QGIS_PREFIX_PATH from older setups).
export QGIS_PREFIX_PATH="$QGIS_APP"
export QGIS_PLUGIN_PATH="$QGIS_APP/Contents/PlugIns/qgis"
export QGIS_PKG_DATA_PATH="$QGIS_APP/Contents/Resources/qgis"

# Headless metatile rendering (also set in render_tiles.sh as a fallback).
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
# Avoid Qt rejecting large SVG/raster symbol buffers during metatile paint
# (seen as "QImageIOHandler: … exceeds … 512 megabytes" on dense z17+).
export QT_IMAGEIO_MAXALLOC="${QT_IMAGEIO_MAXALLOC:-0}"

# Quiet PROJ/GDAL lookup noise when running outside the GUI.
if [[ -d "$QGIS_APP/Contents/Resources/qgis/proj" ]]; then
  export PROJ_DATA="${PROJ_DATA:-$QGIS_APP/Contents/Resources/qgis/proj}"
  export PROJ_LIB="${PROJ_LIB:-$PROJ_DATA}"
fi
if [[ -d "$QGIS_APP/Contents/Resources/qgis/gdal" ]]; then
  export GDAL_DATA="${GDAL_DATA:-$QGIS_APP/Contents/Resources/qgis/gdal}"
fi
