# SPDX-License-Identifier: Apache-2.0
"""Mistral 4 runtime patch installer — registers ``jang_tools/mistral4_mlx.py``
into ``sys.modules`` as ``mlx_lm.models.mistral4`` so ``mlx_lm.utils.load_model``
can resolve ``model_type="mistral4"`` to the JANG-supplied native MLX
implementation.

Architecture: Mistral-Small-4-119B (and siblings) ship HF configs with
top-level ``model_type=mistral3`` (the VLM wrapper class) but
``text_config.model_type=mistral4`` (the inner MLA language model).
``vmlx_engine.utils.jang_loader._load_jang_v2`` promotes ``text_config``
to a flat top-level config so mlx_lm picks the proper Mistral4 model
class — but ``mlx_lm`` itself has no ``mistral4`` model class at the time
of writing. ``jang_tools`` ships ``jang_tools/mistral4_mlx.py`` as a
draft, but its relative imports (``from .activations``, ``.base``,
``.switch_layers``) only resolve when the file's ``__package__`` is
``mlx_lm.models``. Importing it as ``jang_tools.mistral4_mlx`` raises
``ModuleNotFoundError: jang_tools.activations``.

Fix: ``importlib.util.spec_from_file_location`` builds a spec with
``name="mlx_lm.models.mistral4"`` from the on-disk source path, which
sets ``__package__="mlx_lm.models"`` on the resulting module so the
relative imports resolve into the existing ``mlx_lm.models.activations``
/ ``base`` / ``switch_layers``.

Two layers of registration:

  * ``bundle-python.sh`` (release-time) copies ``jang_tools/mistral4_mlx.py``
    to ``mlx_lm/models/mistral4.py`` so ``import mlx_lm.models.mistral4``
    just works on a shipped DMG.
  * This installer (runtime) is the safety net for environments where the
    bundle copy didn't happen — e.g. ``pip install vmlx`` against a
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


def register() -> bool:
    """Install Mistral 4 model_type into mlx_lm's dispatch table.

    Returns
    -------
    bool
        True on success (or already-registered), False if the
        ``jang_tools`` source can't be located.
    """
    if "mlx_lm.models.mistral4" in sys.modules:
        return True

    try:
        import jang_tools  # noqa: F401
    except ImportError:
        logging.getLogger(__name__).warning(
            "Mistral 4 runtime patch: jang_tools unavailable. "
            "Mistral-Small-4 bundles will fail to load; install via "
            "`pip install jang>=2.5.9` or use vMLX's bundled Python."
        )
        return False

    src_path = os.path.join(
        os.path.dirname(jang_tools.__file__), "mistral4_mlx.py"
    )
    if not os.path.isfile(src_path):
        logging.getLogger(__name__).warning(
            "Mistral 4 runtime patch: %s not found in installed "
            "jang_tools. Bump `jang` to a version that ships "
            "mistral4_mlx.py.",
            src_path,
        )
        return False

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
