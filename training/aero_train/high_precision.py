"""Safely load a true RGB16 TIFF without discarding low-order sensor-rendered bits.

Used only by the private Python training pipeline, not the distributed Rust app.
"""
from pathlib import Path

import numpy as np
import tifffile


def read_rgb16_tiff(path: Path) -> np.ndarray | None:
    """Return HWC uint16 RGB data if this is RGB16 TIFF, otherwise None.

    TIFFs that are 16-bit but incompatible are rejected rather than silently
    downsampled into PIL RGB8. Requires already-oriented RGB images; AeroEnhance
    exports are oriented during RAW development.
    """
    if path.suffix.lower() not in ('.tif', '.tiff'):
        return None
    with tifffile.TiffFile(path) as f:
        page = f.pages[0]
        if page.dtype != np.dtype('uint16'):
            return None
        orientation = page.tags.get('Orientation')
        if orientation is not None and int(orientation.value) != 1:
            raise ValueError('Rotate 16-bit TIFF to normal orientation before training')
        arr = page.asarray()
    if arr.ndim != 3 or arr.shape[2] != 3 or arr.dtype != np.uint16:
        raise ValueError(f'16-bit TIFF must be RGB H×W×3 uint16: {path}')
    if arr.shape[0] < 1 or arr.shape[1] < 1:
        raise ValueError(f'Empty 16-bit TIFF: {path}')
    return arr
