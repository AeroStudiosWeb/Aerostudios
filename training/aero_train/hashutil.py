"""Tiny dependency-free checksum helper shared by dataset download and training."""
from __future__ import annotations

import hashlib
from pathlib import Path


def sha256_file(path: Path) -> str:
    dig = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            dig.update(block)
    return dig.hexdigest()
