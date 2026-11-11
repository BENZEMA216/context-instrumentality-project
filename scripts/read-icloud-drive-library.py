#!/usr/bin/env python3
"""Read only one explicitly selected iCloud Drive export; installs no service."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "AgentBridge"))
from icloud_drive_library import main


if __name__ == "__main__":
    sys.exit(main())
