"""Training dataset reader with provenance, grouping and deletion/expiry checks."""
import hashlib
import json
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from .high_precision import read_rgb16_tiff
from .hashutil import sha256_file  # Keep existing aero_train.data.sha256_file import compatible.
from torch.utils.data import Dataset
import torch


def check_record(item: dict, *, verify_hash: bool = True) -> None:
    if item.get('license') != 'operator-verified-training-permission':
        raise ValueError('Missing training permission/license: ' + str(item.get('path')))
    path = Path(item['path'])
    if not path.is_file() or path.is_symlink():
        raise ValueError('Image missing/deleted or symlink not allowed: ' + str(path))
    if not item.get('group'):
        raise ValueError('Every image needs a photographer/session group')
    if item.get('source') == 'feedback':
        meta_path = Path(item['metadata_path'])
        if not meta_path.is_file() or meta_path.is_symlink():
            raise ValueError('Contribution withdrawn or missing: ' + str(meta_path))
        meta = json.loads(meta_path.read_text(encoding='utf-8'))
        if not meta.get('training_permission') or not meta.get('with_example'):
            raise ValueError('Contribution has no training opt-in')
        if meta.get('expires_unix', 0) <= int(time.time()):
            raise ValueError('Contribution expired; no longer eligible')
        if meta.get('id') != item.get('contribution_id'):
            raise ValueError('Contribution identity changed')
        if meta.get('before_sha256') != item['sha256']:
            raise ValueError('Contribution content hash mismatch')
    if verify_hash and sha256_file(path) != item['sha256']:
        raise ValueError('Training image changed: ' + str(path))


def load_manifest(path: Path, *, verify_hash: bool = True) -> list[dict]:
    if not path.is_file():
        raise ValueError(f'No dataset manifest: {path}')
    records = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
    if not records:
        raise ValueError('Dataset is empty')
    seen = set()
    for item in records:
        check_record(item, verify_hash=verify_hash)
        if item['sha256'] in seen:
            raise ValueError('Duplicate clean image in manifest: ' + item['sha256'])
        seen.add(item['sha256'])
    return records


def grouped_split(records: list[dict]) -> dict[str, list[dict]]:
    """Deterministic, *group-isolated* size-aware train/val/test split.

    With only three sessions the two smallest are held out. With a larger
    corpus, aim to reserve ~10%% of photographs per holdout while keeping most
    images available for training. The chosen split is fingerprinted into new
    training checkpoints, so changing group sizes cannot silently resume.
    """
    by_group = {}
    for r in records:
        by_group.setdefault(r['group'], []).append(r)
    if len(by_group) < 3:
        raise ValueError('Need at least THREE distinct photographer/session groups for independent train/val/test sets')
    tie = lambda g: hashlib.sha256(g.encode()).hexdigest()
    groups = sorted(by_group, key=tie)
    total = len(records)
    labels = {g: 'train' for g in groups}
    if len(groups) == 3:
        # Avoid the old failure mode, where hashing sometimes assigned the
        # 3-photo session as the *only* training session.
        smallest = sorted(groups, key=lambda g: (len(by_group[g]), tie(g)))
        labels[smallest[0]] = 'test'
        labels[smallest[1]] = 'val'
    else:
        remaining = set(groups)
        target = max(10, int(total * 0.1))
        for split_name in ('test', 'val'):
            selected = []
            count = 0
            # Always reserve one group for the other holdout and one for train.
            reserved = 2 if split_name == 'test' else 1
            while len(remaining) > reserved and (count < target or not selected):
                options = sorted(remaining, key=lambda g: (
                    abs(target - count - len(by_group[g])),
                    len(by_group[g]), tie(g)))
                chosen = options[0]
                # Do not take an enormous creator group just to fill a holdout;
                # if it is unavoidable, the dataset audit shows the problem.
                if selected and count >= max(1, int(target * 0.6)) and count + len(by_group[chosen]) > target * 1.25:
                    break
                remaining.remove(chosen)
                selected.append(chosen)
                count += len(by_group[chosen])
            for group in selected:
                labels[group] = split_name
    split = {k: [] for k in ('train', 'val', 'test')}
    for rec in records:
        split[labels[rec['group']]].append(rec)
    return split


class CleanCrops(Dataset):
    def __init__(self, records: list[dict], patch: int = 128, augment: bool = True, seed: int = 0):
        self.records, self.patch, self.augment, self.seed = records, patch, augment, seed
        if not records:
            raise ValueError('Empty dataset split')

    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        r = self.records[index % len(self.records)]
        # Includes consent/expiry check every access, not just at dataset preparation.
        check_record(r, verify_hash=True)
        # Deterministic val crops; random crops during training.
        rgb16 = read_rgb16_tiff(Path(r['path']))
        if rgb16 is not None:
            h, w = rgb16.shape[:2]
        else:
            with Image.open(r['path']) as f:
                img = ImageOps.exif_transpose(f).convert('RGB')
            w, h = img.size
        if min(w, h) < self.patch:
            raise ValueError(f'Image smaller than requested {self.patch}px crop: {r["path"]}')
        if self.augment:
            import random
            x, y = random.randint(0, w-self.patch), random.randint(0, h-self.patch)
        else:
            rng = int(hashlib.sha256((r['sha256']+str(self.seed)).encode()).hexdigest()[:8],16)
            x = rng % (w-self.patch+1)
            y = (rng // 337) % (h-self.patch+1)
        if rgb16 is not None:
            arr = rgb16[y:y+self.patch, x:x+self.patch].copy()
            if self.augment:
                import random
                if random.getrandbits(1): arr = np.flip(arr, axis=1)
                if random.getrandbits(1): arr = np.flip(arr, axis=0)
                arr = np.rot90(arr, random.choice([0,1,2,3]))
            arr = np.ascontiguousarray(arr, dtype=np.float32) / 65535.0
        else:
            img = img.crop((x,y,x+self.patch,y+self.patch))
            if self.augment:
                import random
                if random.getrandbits(1): img = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                if random.getrandbits(1): img = img.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
                img = img.rotate(random.choice([0,90,180,270]))
            arr = np.asarray(img, dtype=np.float32).copy() / 255.0
        return torch.from_numpy(arr).permute(2,0,1).contiguous()
