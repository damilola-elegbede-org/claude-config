"""Shim — delegates to office-common/scripts/office/helpers/merge_runs.py."""
import sys
import os

_common = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "office-common", "scripts")
)
if _common not in sys.path:
    sys.path.insert(0, _common)

from office.helpers.merge_runs import *  # noqa: F401, F403
from office.helpers.merge_runs import merge_runs  # noqa: E402
