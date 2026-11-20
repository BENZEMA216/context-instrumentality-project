"""Shared raw-event contract for a source checkout or installed package."""
import json
import sysconfig
from functools import lru_cache
from pathlib import Path

from jsonschema import Draft202012Validator


def data_file(relative):
    """Resolve distribution data for a checkout, --target installation, or normal prefix."""
    package_root = Path(__file__).resolve().parent.parent
    shared = Path("share/context-instrumentality-project") / Path(relative).name
    for path in (package_root / relative, package_root / shared, Path(sysconfig.get_path("data")) / shared):
        if path.is_file():
            return path
    raise FileNotFoundError(f"Missing context-hub resource {Path(relative).name}. Reinstall the distribution.")


@lru_cache(maxsize=1)
def _validator():
    schema = data_file("schema/context-event.schema.json")
    return Draft202012Validator(json.loads(schema.read_text(encoding="utf-8")))


def validate_event(event):
    error = next(_validator().iter_errors(event), None)
    if error:
        field = ".".join(map(str, error.absolute_path)) or "event"
        raise ValueError(f"Invalid ContextEvent: {field} ({error.validator})")
