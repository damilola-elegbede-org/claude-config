"""Shim — delegates to office-common/scripts/office/unpack.py."""
import sys
import os

_common = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "office-common", "scripts")
)
if _common not in sys.path:
    sys.path.insert(0, _common)

from office.unpack import *  # noqa: F401, F403, E402
from office.unpack import main  # noqa: E402

if __name__ == "__main__":
    main()
