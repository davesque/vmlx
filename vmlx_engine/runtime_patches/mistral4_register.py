# SPDX-License-Identifier: Apache-2.0
"""Mistral 4 runtime patch installer — registers the vendored
``_mistral4_native.py`` (or, as a fallback, ``jang_tools/mistral4_mlx.py``)
into ``sys.modules`` as ``mlx_lm.models.mistral4`` so ``mlx_lm.utils.load_model``
can resolve ``model_type="mistral4"`` to a native MLX implementation.

Architecture: Mistral-Small-4-119B (and siblings) ship HF configs with
top-level ``model_type=mistral3`` (the VLM wrapper class) but
``text_config.model_type=mistral4`` (the inner MLA language model).
``vmlx_engine.utils.jang_loader._load_jang_v2`` promotes ``text_config``
to a flat top-level config so mlx_lm picks the proper Mistral4 model
class — but ``mlx_lm`` itself has no ``mistral4`` model class at the time
of writing.

Two candidate sources, in priority order:

  1. ``vmlx_engine.runtime_patches._mistral4_native`` — the upstream
     mlx_lm-shaped implementation that depends on
     ``mlx_lm.models.{mla,pipeline,rope_utils}``. This is the version
     vMLX 1.4.0+ ships and exercises in production. The standalone
     ``jang_tools.mistral4_mlx`` is an older draft that mis-handles
     YaRN scaling for the JANG-promoted config and produces gibberish
     decode tokens — confirmed against
     ``JANGQ-AI/Mistral-Small-4-119B-A6B-JANG_4M``.
  2. ``jang_tools/mistral4_mlx.py`` — kept as a fallback for installs
     where vmlx_engine has been stripped down (vendored without
     ``runtime_patches`` data files).

Both files use relative imports (``from .activations``, ``.base``,
``.mla``, ``.pipeline``, ``.rope_utils``, ``.switch_layers``) which only
resolve when the module's ``__package__`` is ``mlx_lm.models``.
``importlib.util.spec_from_file_location`` lets us load the file under
that fully qualified name without copying it into the install tree.

Two layers of registration:

  * ``bundle-python.sh`` (release-time) copies the vendored native
    source to ``mlx_lm/models/mistral4.py`` so ``import
    mlx_lm.models.mistral4`` just works on a shipped DMG.
  * This installer (runtime) is the safety net for environments where
    the bundle copy didn't happen — e.g. ``pip install vmlx`` against a
    user-managed Python — and is also imported lazily from
    ``jang_loader._load_jang_v2`` at the mistral4 promotion site so we
    never depend on import-order luck.

Idempotent: re-running is a no-op if ``mlx_lm.models.mistral4`` is
already in ``sys.modules``.
"""

from __future__ import annotations

import logging
import os
import sys

logger = logging.getLogger(__name__)


def _vendored_native_source() -> str | None:
    """Return the absolute path to the vendored mistral4 source, or ``None``."""
    src = os.path.join(os.path.dirname(__file__), "_mistral4_native.py")
    return src if os.path.isfile(src) else None


def _jang_tools_source() -> str | None:
    """Return the absolute path to ``jang_tools/mistral4_mlx.py``, or ``None``.

    Older fallback — the standalone implementation does not match the
    JANG-promoted config and produces gibberish on decode, but it is
    still better than failing to load at all if our vendored copy got
    lost during packaging.
    """
    try:
        import jang_tools  # noqa: F401
    except ImportError:
        return None
    src = os.path.join(os.path.dirname(jang_tools.__file__), "mistral4_mlx.py")
    return src if os.path.isfile(src) else None


def register() -> bool:
    """Install Mistral 4 model_type into mlx_lm's dispatch table.

    Returns
    -------
    bool
        True on success (or already-registered), False if no source
        file could be located.
    """
    if "mlx_lm.models.mistral4" in sys.modules:
        return True

    src_path = _vendored_native_source()
    if src_path is None:
        src_path = _jang_tools_source()
        if src_path is None:
            logger.warning(
                "Mistral 4 runtime patch: neither the vendored "
                "_mistral4_native.py nor jang_tools/mistral4_mlx.py "
                "could be located. Mistral-Small-4 bundles will fail "
                "to load."
            )
            return False
        logger.warning(
            "Mistral 4 runtime patch: vendored _mistral4_native.py "
            "missing — falling back to jang_tools/mistral4_mlx.py "
            "(may produce incorrect output)."
        )

    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "mlx_lm.models.mistral4", src_path
    )
    if spec is None or spec.loader is None:
        return False

    mod = importlib.util.module_from_spec(spec)
    sys.modules["mlx_lm.models.mistral4"] = mod
    try:
        spec.loader.exec_module(mod)
    except Exception:
        del sys.modules["mlx_lm.models.mistral4"]
        raise
    return True


# Auto-install on package import so callers never forget.
register()
