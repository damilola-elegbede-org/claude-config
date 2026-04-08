"""Shim — re-exports from office-common validators."""
import sys
import os

_common = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "office-common", "scripts")
)
if _common not in sys.path:
    sys.path.insert(0, _common)

from office.validators import *  # noqa: F401, F403
from office.validators import BaseSchemaValidator, DOCXSchemaValidator, PPTXSchemaValidator, RedliningValidator  # noqa: E402

__all__ = [
    "BaseSchemaValidator",
    "DOCXSchemaValidator",
    "PPTXSchemaValidator",
    "RedliningValidator",
]
