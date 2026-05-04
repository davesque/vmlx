#!/bin/bash
set -euo pipefail

# Build a relocatable Python environment with all vmlx-engine dependencies.
# Run once on dev machine before `npm run dist`.
# Output: panel/bundled-python/python/ (~1-2 GB)

PYTHON_VERSION="3.12.12"
BUILD_DATE="20260211"
ARCH="aarch64-apple-darwin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$PANEL_DIR")"
BUNDLE_DIR="$PANEL_DIR/bundled-python"

echo "==> Bundling Python $PYTHON_VERSION for standalone vMLX distribution"

# Clean previous build
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Download python-build-standalone (Astral's relocatable Python builds)
TARBALL="cpython-${PYTHON_VERSION}+${BUILD_DATE}-${ARCH}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${BUILD_DATE}/${TARBALL}"
echo "==> Downloading Python ${PYTHON_VERSION}..."
curl -L "$URL" | tar xz -C "$BUNDLE_DIR"

PYTHON="$BUNDLE_DIR/python/bin/python3"

# Verify Python works
"$PYTHON" --version

# Upgrade pip
echo "==> Upgrading pip..."
"$PYTHON" -m pip install --upgrade pip

# Install ALL dependencies (lean: no gradio, no dev tools, no pytz)
# Uses opencv-python-headless instead of opencv-python (no GUI deps, smaller)
echo "==> Installing dependencies..."
"$PYTHON" -m pip install \
  "mlx>=0.29.0" "mlx-lm>=0.30.2" "mlx-vlm>=0.1.0" \
  "transformers>=5.4.0" "tokenizers>=0.19.0" "huggingface-hub>=0.23.0" \
  "numpy>=1.24.0" "pillow>=10.0.0" \
  "opencv-python-headless>=4.8.0" \
  "fastapi>=0.100.0" "uvicorn>=0.23.0" \
  "mcp>=1.0.0" "jsonschema>=4.0.0" \
  "psutil>=5.9.0" "tqdm>=4.66.0" "pyyaml>=6.0" \
  "requests>=2.28.0" "tabulate>=0.9.0" "mlx-embeddings>=0.0.5" \
  "tiktoken>=0.7.0" \
  "soundfile>=0.12" \
  "timm>=1.0.20"  # Kimi K2.6 tokenizer + Nemotron-Omni audio (soundfile) + Omni RADIO ViT (timm)

# Install mlx-audio for STT/TTS (--no-deps: it pins exact mlx-lm/transformers versions
# that conflict with ours — we already have all the real deps above)
echo "==> Installing mlx-audio (STT/TTS)..."
"$PYTHON" -m pip install --no-deps "mlx-audio>=0.2.0"
# Install mlx-audio's transitive deps that we don't already have
"$PYTHON" -m pip install \
  librosa sounddevice miniaudio pyloudnorm numba

# Install vmlx-engine from PyPI (the local repo's pyproject.toml has a
# `setuptools.package-dir = engine` declaration that breaks `pip install
# .` here because the panel dir lives at panel/, not engine/. PyPI 1.4.3
# is a clean wheel with the same source so this is equivalent.)
#
# jang_tools — install from LOCAL source path, not PyPI. The published
# `jang` wheel lags the local development of jang_tools.dsv4 modules
# (pool_quant_cache.py, fused_pool_attn.py, fused_pool_attn_kernel.py,
# build_role_codebooks.py landed in jang 2.5.10 but only jang 2.5.9 was
# on PyPI as of v1.5.2 build, causing
# `ModuleNotFoundError: No module named 'jang_tools.dsv4.pool_quant_cache'`
# the moment a DSV4-Flash bundle was loaded). Pinning to local source
# ensures every DMG ships with whatever DSV4 runtime the engine actually
# needs. Falls back to PyPI if the local path doesn't exist (CI builds).
echo "==> Installing vmlx-engine + jang_tools (local source)..."
"$PYTHON" -m pip install --no-deps "vmlx==1.4.3"
JANG_LOCAL="$HOME/jang/jang-tools"
if [ -f "$JANG_LOCAL/pyproject.toml" ]; then
  echo "    using local jang-tools at $JANG_LOCAL"
  "$PYTHON" -m pip install --no-deps "$JANG_LOCAL"
else
  echo "    local jang-tools missing, falling back to PyPI"
  "$PYTHON" -m pip install --no-deps "jang>=2.5.11"
fi

# Verify it works
echo "==> Verifying installation..."
"$PYTHON" -c "import vmlx_engine; print(f'vmlx_engine {vmlx_engine.__version__} imported OK')"
"$PYTHON" -m vmlx_engine.cli --help > /dev/null 2>&1 && echo "CLI OK"

# Clean up to reduce size
echo "==> Cleaning up..."
SITE="$BUNDLE_DIR/python/lib/python3.12/site-packages"

# Python bytecode (regenerated on import)
find "$BUNDLE_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -name "*.pyc" -delete 2>/dev/null || true

# Unused stdlib modules
rm -rf "$BUNDLE_DIR/python/lib/python3.12/test"
rm -rf "$BUNDLE_DIR/python/lib/python3.12/ensurepip"
rm -rf "$BUNDLE_DIR/python/lib/python3.12/idlelib"
rm -rf "$BUNDLE_DIR/python/lib/python3.12/tkinter"
rm -rf "$BUNDLE_DIR/python/lib/python3.12/turtle"*
rm -rf "$BUNDLE_DIR/python/share" 2>/dev/null || true
# Unused .so for removed stdlib (tkinter)
rm -f "$BUNDLE_DIR/python/lib/python3.12/lib-dynload/_tkinter"*.so 2>/dev/null || true

# Test suites in site-packages (~80+ MB of test data never used at runtime)
find "$SITE" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$SITE" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true

# Packages not needed at runtime (transitive deps / dev-only tools)
# torch/torchvision: vmlx-engine uses MLX, not PyTorch. torch's bundled copy is
# broken (missing torchgen) and causes ModuleNotFoundError on startup.
# transformers gracefully degrades without torch via is_torch_available().
rm -rf "$SITE/torch" "$SITE/torch-"*.dist-info 2>/dev/null || true
rm -rf "$SITE/torchvision" "$SITE/torchvision-"*.dist-info 2>/dev/null || true
rm -rf "$SITE/torchgen" "$SITE/torchgen-"*.dist-info 2>/dev/null || true
# soundfile: KEEP. Required for Nemotron-3-Nano-Omni audio path
# (jang_tools.nemotron_omni_chat → ParakeetEncoder mel features).
# Modern pip install ships libsndfile_arm64.dylib alongside _soundfile_data,
# so the older "missing libsndfile.dylib" runtime crash no longer applies.
# Verified working at bundle time: see verify-bundled-python.sh soundfile gate.
rm -rf "$SITE/setuptools" 2>/dev/null || true          # build tool, not needed at runtime (~4.2 MB)
rm -rf "$SITE/setuptools"*.dist-info 2>/dev/null || true

# Keep pip intact (needed for engine auto-update at runtime via python3 -m pip)
# NOTE: Do NOT remove pip/_vendor/* — pip 26+ requires cachecontrol, pygments,
# rich, and other vendored modules. Removing them breaks `python3 -m pip install`.
# Only safe to remove: pip's test directories.
find "$SITE/pip" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true

# ====================================================================
# Patches for bundled dependencies (apply AFTER pip install, AFTER cleanup)
# These fix issues in transformers/mlx-vlm for torch-free environments.
# ====================================================================
echo "==> Applying bundled dependency patches..."

# 1. transformers/processing_utils.py: Allow None sub-processors (video_processor)
#    Without torchvision, Qwen2VL's video_processor loads as None. The type check
#    must allow None so image-only VLM usage works.
sed -i '' 's/if not isinstance(argument, proper_class):/if argument is not None and not isinstance(argument, proper_class):/' \
  "$SITE/transformers/processing_utils.py"

# 2. transformers/processing_utils.py: Skip ImportError when loading sub-processors
#    Video processor requires torchvision; gracefully skip when unavailable.
#
#    Two call paths can fail in the torch-free bundle:
#      a) auto_processor_class.from_pretrained(...) where auto_processor_class is
#         AutoVideoProcessor — fails inside the Auto dispatch on torchvision import.
#      b) For processors that still declare the deprecated `<modality>_class`
#         attribute (e.g. Qwen3VLProcessor.video_processor_class = "Qwen3VLVideoProcessor"),
#         the loader resolves auto_processor_class to the *dummy* class via
#         get_possibly_dynamic_module(), and then `auto_processor_class.from_pretrained`
#         attribute access alone triggers DummyObject.__getattribute__ which calls
#         requires_backends() → ImportError("Qwen3VLVideoProcessor requires the
#         Torchvision library ...").
#
#    Wrapping the *entire* dispatch (the hasattr/get_possibly_dynamic_module branch
#    plus the from_pretrained call) in try/except ImportError handles both. We use
#    Python AST/text scanning to be resilient to whitespace + future additions
#    inside the elif block (transformers 5.x grew the deprecation warning in 5.4
#    and may grow again).
"$PYTHON" - "$SITE/transformers/processing_utils.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

if 'vMLX bundled-python patch' in content:
    print('  Already patched: processing_utils.py sub-processor (vMLX marker present)')
    sys.exit(0)

# Locate the elif is_primary block and wrap from `auto_processor_class = ...`
# through `args.append(sub_processor)` in try/except ImportError. Match by
# anchoring on the unique header lines to survive minor whitespace changes.
import re
pat = re.compile(
    r'(            elif is_primary:\n'
    r'                # Primary non-tokenizer sub-processor: load via Auto class\n)'
    r'(                auto_processor_class = MODALITY_TO_AUTOPROCESSOR_MAPPING\[sub_processor_type\]\n'
    r'(?:.+\n)*?'
    r'                args\.append\(sub_processor\)\n)',
    re.MULTILINE,
)
m = pat.search(content)
if m is None:
    print('  Skipped: processing_utils.py elif-is_primary block not found '
          '(transformers source restructured? — patch needs update)')
    sys.exit(0)

header, body = m.group(1), m.group(2)
indented = ''.join('    ' + line if line.strip() else line for line in body.splitlines(keepends=True))
replacement = (
    header
    + '                # vMLX bundled-python patch: wrap dispatch in try/except\n'
    + '                # ImportError so video processors that need torch/torchvision\n'
    + '                # degrade to image-only mode in the torch-free bundle. Covers\n'
    + '                # both AutoVideoProcessor.from_pretrained AND the deprecated\n'
    + '                # `<modality>_class` path that resolves to a dummy class via\n'
    + '                # get_possibly_dynamic_module (whose __getattribute__ raises\n'
    + '                # ImportError on attribute access, including from_pretrained).\n'
    + '                try:\n'
    + indented
    + '                except ImportError:\n'
    + '                    # Skip sub-processors needing unavailable backends\n'
    + '                    # (video → torchvision).\n'
    + '                    pass\n'
)
content = content[:m.start()] + replacement + content[m.end():]
with open(path, 'w') as f:
    f.write(content)
# Compile-check immediately so we never ship a syntax-broken processing_utils.py
import ast
ast.parse(content)
print('  Patched: processing_utils.py sub-processor ImportError handling (vMLX)')
PYEOF

# 3. transformers/models/auto/video_processing_auto.py: Null check for extractors
#    transformers 5.2.0 bug where extractors can be None
sed -i '' 's/if class_name in extractors:/if extractors is not None and class_name in extractors:/' \
  "$SITE/transformers/models/auto/video_processing_auto.py" 2>/dev/null || true

# 4. mlx_vlm/utils.py: Lazy-import soundfile (defense-in-depth)
#    Even after removing the soundfile package, patch the import to be lazy
#    in case soundfile gets pulled back in as a transitive dep.
sed -i '' 's/^import soundfile as sf$/# import soundfile as sf  # lazy-loaded: see _get_sf()/' \
  "$SITE/mlx_vlm/utils.py" 2>/dev/null || true

# 5. mlx_vlm/models/qwen3_5/language.py: Fix mRoPE dimension mismatch for MoE
#    mlx-vlm 0.3.12 bug: broadcasting with cos/sin can produce 5D tensors
"$PYTHON" -c "
path = '$SITE/mlx_vlm/models/qwen3_5/language.py'
try:
    with open(path, 'r') as f:
        content = f.read()
    old = '''    q_embed = (q_rot * cos) + (rotate_half(q_rot) * sin)
    k_embed = (k_rot * cos) + (rotate_half(k_rot) * sin)

    q_embed = mx.concatenate([q_embed, q_pass], axis=-1)'''
    new = '''    q_embed = (q_rot * cos) + (rotate_half(q_rot) * sin)
    k_embed = (k_rot * cos) + (rotate_half(k_rot) * sin)

    # Fix mRoPE dimension mismatch for MoE models: broadcasting with cos/sin
    # can produce 5D tensors when q_pass is 4D (mlx-vlm 0.3.12 bug)
    if q_embed.ndim > q_pass.ndim and q_embed.ndim == 5:
        q_embed = q_embed[0]
        k_embed = k_embed[0]

    q_embed = mx.concatenate([q_embed, q_pass], axis=-1)'''
    if old in content:
        content = content.replace(old, new)
        with open(path, 'w') as f:
            f.write(content)
        print('  Patched: qwen3_5/language.py mRoPE dimension fix')
    else:
        print('  Already patched or structure changed: qwen3_5/language.py')
except FileNotFoundError:
    print('  Skipped: qwen3_5/language.py not found (model not in this mlx-vlm version)')
"

# --- Patch: mlx_lm/models/ssm.py (Mamba/Nemotron-H hybrid state space model) ---
# Fix 1: mx.clip(dt, ...) upper-clips dt values, corrupting Mamba state transitions.
#         Replace with mx.maximum(dt, time_step_limit[0]) — only lower-clip.
# Fix 2: output_dtypes=[input_type, input_type] stores SSM state in bfloat16,
#         causing precision loss. State must be float32.
echo "  Patching mlx_lm/models/ssm.py (Mamba state fixes)..."
python3 -c "
import os, glob
base = '$BUNDLE_DIR/python/lib/python3.*/site-packages/mlx_lm/models/ssm.py'
paths = glob.glob(base)
if not paths:
    print('  Skipped: ssm.py not found')
else:
    path = paths[0]
    with open(path, 'r') as f:
        content = f.read()
    changed = False
    # Fix 1: clip -> maximum (line 10)
    old1 = 'return mx.clip(dt, time_step_limit[0], time_step_limit[1])'
    new1 = 'return mx.maximum(dt, time_step_limit[0])'
    if old1 in content:
        content = content.replace(old1, new1)
        changed = True
        print('  Patched: ssm.py dt clip -> maximum')
    else:
        print('  Already patched or structure changed: ssm.py dt fix')
    # Fix 2: state output dtype must be float32
    old2 = 'output_dtypes=[input_type, input_type]'
    new2 = 'output_dtypes=[input_type, mx.float32]'
    if old2 in content:
        content = content.replace(old2, new2)
        changed = True
        print('  Patched: ssm.py state dtype -> float32')
    else:
        print('  Already patched or structure changed: ssm.py dtype fix')
    if changed:
        with open(path, 'w') as f:
            f.write(content)
"

# --- Patch: install vmlx_engine vendored mistral4 source as mlx_lm/models/mistral4.py ---
# Mistral-Small-4-119B (and siblings) use model_type=mistral4 in text_config —
# vmlx_engine.utils.jang_loader promotes it to the top-level config and
# expects mlx_lm.utils.load_model to find a `mistral4` model class.
#
# mlx_lm itself has no `mistral4.py`. Two candidate sources exist:
#   1. vmlx_engine/runtime_patches/_mistral4_native.py — the upstream
#      mlx_lm-shaped implementation (uses `.mla.MultiLinear`,
#      `.pipeline.PipelineMixin`, `.rope_utils.initialize_rope`). This
#      matches what JANG bundles are quantized against and is what vMLX
#      1.4.0+ ships and exercises in production.
#   2. jang_tools/mistral4_mlx.py — older standalone draft. Mis-handles
#      the YaRN scaling for the JANG-promoted config and produces
#      gibberish decode tokens. Kept only as a last-resort fallback.
#
# Both files use relative imports (`from .mla`, `.activations`, etc.) that
# only resolve when the file lives next to those siblings under
# mlx_lm/models/, so we have to physically copy.
#
# Idempotent — re-running overwrites with the current vendored source.
echo "  Installing mistral4 model file (vmlx_engine vendored → mlx_lm/models/mistral4.py)..."
python3 -c "
import os, shutil
site = '$SITE'
# Order matters: prefer vendored native source over jang_tools fallback.
candidates = [
    os.path.join(site, 'vmlx_engine', 'runtime_patches', '_mistral4_native.py'),
    os.path.join(site, 'jang_tools', 'mistral4_mlx.py'),
]
src = next((p for p in candidates if os.path.isfile(p)), None)
dst = os.path.join(site, 'mlx_lm', 'models', 'mistral4.py')
if src is None:
    print('  Skipped: no mistral4 source found (vmlx_engine + jang_tools both missing?)')
elif not os.path.isdir(os.path.dirname(dst)):
    print('  Skipped: mlx_lm/models/ not found')
else:
    shutil.copyfile(src, dst)
    print(f'  Installed: {dst} (from {src})')
"

echo "==> Patches applied."

# ====================================================================
# Critical: Verify the Python shared library exists (prevents broken bundles)
# The bundled Python MUST include libpython3.12.dylib for the app to work.
# Without it, the app falls back to system Python which may have outdated or
# missing packages (e.g., mlx_vlm without qwen3_5_moe support).
# ====================================================================
echo "==> Verifying Python shared library..."
LIBPYTHON="$BUNDLE_DIR/python/lib/libpython3.12.dylib"
if [ -f "$LIBPYTHON" ]; then
  echo "  libpython3.12.dylib OK ($(du -h "$LIBPYTHON" | cut -f1))"
else
  # Check if it exists elsewhere in the bundle (some builds put it in different locations)
  FOUND=$(find "$BUNDLE_DIR" -name "libpython3.12*.dylib" 2>/dev/null | head -1)
  if [ -n "$FOUND" ]; then
    echo "  Found at: $FOUND — creating symlink"
    ln -sf "$FOUND" "$LIBPYTHON"
  else
    echo "ERROR: libpython3.12.dylib NOT FOUND in bundle!"
    echo "  The app will fall back to system Python, which may have outdated packages."
    echo "  This is a critical build issue — the bundle is incomplete."
    exit 1
  fi
fi

# Post-cleanup verification: ensure pip still works (catches vendor stripping bugs)
echo "==> Verifying pip is functional (needed for engine auto-update)..."
"$PYTHON" -s -m pip --version > /dev/null 2>&1 || { echo "ERROR: pip is broken after cleanup! Check vendor removals."; exit 1; }
echo "  pip OK"

# Critical: reject editable installs (prevents shipping dev-machine paths to users)
echo "==> Checking for editable installs..."
EDITABLE_PTH=$(find "$SITE" -maxdepth 1 -name "__editable__.*" -o -name "__editable___*" 2>/dev/null)
if [ -n "$EDITABLE_PTH" ]; then
  echo "ERROR: Editable install detected in bundled Python!"
  echo "  Found: $EDITABLE_PTH"
  echo "  This would ship with hardcoded paths to your dev machine."
  echo "  Fix: re-run bundle-python.sh from scratch (it cleans the bundle dir)."
  exit 1
fi
echo "  No editable installs (good)"

# Verify path isolation
echo "==> Verifying path isolation..."
ENABLE_USER_SITE=$("$PYTHON" -s -c "import site; print(site.ENABLE_USER_SITE)" 2>&1)
if [ "$ENABLE_USER_SITE" = "False" ]; then
  echo "  ENABLE_USER_SITE=False with -s flag OK"
else
  echo "WARNING: -s flag did not suppress user site-packages"
fi

echo ""
echo "==> Bundle size:"
du -sh "$BUNDLE_DIR"
echo ""
echo "==> Done! Bundled Python ready at: $BUNDLE_DIR"
echo "    Next: npm run build && npx electron-builder --mac"
