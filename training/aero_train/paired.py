"""Curated aligned noisy/clean pairs for optional supervised fine-tuning.

Pairs are separate from unpaired clean images; never infer clean truth from
AeroEnhance's own output. ALL files stay on the operator's local machine.
"""
import argparse
import json
import os
import random
import uuid
from pathlib import Path

import numpy as np
import tifffile
import torch
from PIL import Image, ImageOps
from torch.utils.data import Dataset

from .data import sha256_file
from .dataset_cli import LICENSE, SUPPORTED
from .high_precision import read_rgb16_tiff


def _rgb(path: Path) -> np.ndarray:
    hi = read_rgb16_tiff(path)
    if hi is not None:
        return hi
    with Image.open(path) as f:
        return np.array(ImageOps.exif_transpose(f).convert('RGB'))


def _image_files(folder: Path) -> dict[str, Path]:
    out = {}
    for file in sorted(folder.rglob('*')):
        if not file.is_file() or file.is_symlink() or file.suffix.lower() not in SUPPORTED:
            continue
        # Relative stem retains session folders, preventing burst-photo collisions.
        key = str(file.relative_to(folder).with_suffix('')).casefold()
        if key in out:
            raise ValueError(f'Ambiguous duplicate image stem: {key}')
        out[key] = file
    return out


def load_pairs(dataset: Path, verify_hash=True) -> list[dict]:
    manifest = dataset / 'pairs.jsonl'
    if not manifest.exists():
        raise ValueError(f'No paired dataset: {manifest}')
    records = [json.loads(line) for line in manifest.read_text(encoding='utf-8').splitlines() if line.strip()]
    if not records:
        raise ValueError('Paired dataset is empty')
    seen = set()
    for row in records:
        if row.get('license') != LICENSE or not row.get('group'):
            raise ValueError('Missing rights confirmation or group for paired data')
        for field, hash_field in [('clean_path','clean_sha256'),('noisy_path','noisy_sha256')]:
            path = Path(row[field]); value = row[hash_field]
            if not path.is_file() or path.is_symlink():
                raise ValueError('Paired image deleted/missing: ' + str(path))
            if verify_hash and sha256_file(path) != value:
                raise ValueError('Paired image has changed: ' + str(path))
        pair_id = (row['clean_sha256'], row['noisy_sha256'])
        if pair_id in seen:
            raise ValueError('Duplicate clean/noisy pair')
        seen.add(pair_id)
    return records


def import_pairs(args):
    if not args.rights_confirmed:
        raise ValueError('Explicit --rights-confirmed required for BOTH clean and noisy images')
    if not args.group.strip() or args.group.lower() in {'unknown', 'default'}:
        raise ValueError('Use a genuine shared photographer/session group')
    clean_dir, noisy_dir, dataset = Path(args.clean), Path(args.noisy), Path(args.dataset)
    if not clean_dir.is_dir() or not noisy_dir.is_dir():
        raise ValueError('Clean and noisy directories must both exist')
    if dataset.resolve().is_relative_to(clean_dir.resolve()) or dataset.resolve().is_relative_to(noisy_dir.resolve()):
        raise ValueError('Dataset output must be outside source folders')
    c, n = _image_files(clean_dir), _image_files(noisy_dir)
    if not c or c.keys() != n.keys():
        missing = sorted(c.keys() ^ n.keys())[:10]
        raise ValueError(f'Clean/noisy stems must match exactly; unmatched: {missing}')
    dataset.mkdir(parents=True, exist_ok=True)
    stage = dataset / 'aligned'; stage.mkdir(exist_ok=True)
    manifest = dataset / 'pairs.jsonl'
    current = [json.loads(s) for s in manifest.read_text(encoding='utf-8').splitlines() if s.strip()] if manifest.exists() else []
    existing = {(x['clean_sha256'], x['noisy_sha256']) for x in current}
    new_files = []
    try:
        for key in sorted(c):
            clean, noisy = _rgb(c[key]), _rgb(n[key])
            if clean.shape != noisy.shape or min(clean.shape[:2]) < args.min_side:
                raise ValueError(f'Pair must be aligned, same size/depth and >= {args.min_side}px: {key}')
            if clean.dtype != noisy.dtype:
                raise ValueError(f'Mixed 8/16 bit pairs are not supported: {key}')
            suffix = '.tiff' if clean.dtype == np.uint16 else '.png'
            stem = uuid.uuid4().hex
            cp, npth = stage / (stem+'-clean'+suffix), stage / (stem+'-noisy'+suffix)
            if suffix == '.tiff':
                tifffile.imwrite(cp, clean, photometric='rgb', metadata=None)
                tifffile.imwrite(npth, noisy, photometric='rgb', metadata=None)
            else:
                Image.fromarray(clean, 'RGB').save(cp)
                Image.fromarray(noisy, 'RGB').save(npth)
            new_files.extend((cp,npth))
            ch, nh = sha256_file(cp), sha256_file(npth)
            if (ch,nh) in existing:
                cp.unlink(); npth.unlink(); new_files = new_files[:-2]
                continue
            current.append({'clean_path':str(cp.resolve()),'noisy_path':str(npth.resolve()),
                            'clean_sha256':ch,'noisy_sha256':nh,'group':args.group,
                            'license':LICENSE,'source':'aligned-pair'})
            existing.add((ch,nh))
        temp = manifest.with_suffix('.jsonl.part')
        temp.write_text(''.join(json.dumps(x,sort_keys=True)+'\n' for x in current),encoding='utf-8')
        os.replace(temp,manifest)
    except Exception:
        for file in new_files:
            file.unlink(missing_ok=True)
        raise
    print(f'Pairs now in private dataset: {len(current)}. Align pairs before importing; matching sizes alone do not prove alignment.')


def import_pair_library(args):
    """One import for ROOT/SESSION/{clean,noisy}/... aligned photo sessions."""
    import re
    if not args.rights_confirmed:
        raise ValueError('Explicit --rights-confirmed required')
    root = Path(args.input)
    if not root.is_dir():
        raise ValueError('Paired-library root does not exist')
    sessions = sorted(d for d in root.iterdir() if d.is_dir() and not d.is_symlink())
    if len(sessions) < 3:
        raise ValueError('Need THREE distinct aligned-pair session folders')
    for folder in sessions:
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',folder.name):
            raise ValueError('Anonymise pair session folder names: '+folder.name)
        import_pairs(argparse.Namespace(clean=str(folder/'clean'),noisy=str(folder/'noisy'),
                     dataset=args.dataset,group=folder.name,min_side=args.min_side,
                     rights_confirmed=True))
    print('Finished private aligned-pair library import. Run paired audit next.')


class PairedCrops(Dataset):
    def __init__(self, records: list[dict], patch=128, augment=True, seed=0):
        if not records:
            raise ValueError('Paired split is empty')
        self.records, self.patch, self.augment, self.seed = records, patch, augment, seed

    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        r = self.records[index]
        # Fresh integrity checks ensure withdrawal/deletion and dataset edits halt training.
        for field, hash_field in [('clean_path','clean_sha256'),('noisy_path','noisy_sha256')]:
            path = Path(r[field])
            if not path.is_file() or path.is_symlink() or sha256_file(path) != r[hash_field]:
                raise ValueError(f'Paired dataset changed: {path}')
        clean, noisy = _rgb(Path(r['clean_path'])), _rgb(Path(r['noisy_path']))
        if clean.shape != noisy.shape or min(clean.shape[:2]) < self.patch:
            raise ValueError('Pair dimensions changed or image is too small')
        h,w = clean.shape[:2]
        rng = random if self.augment else random.Random(int(r['clean_sha256'][:12],16)+self.seed)
        y, x = rng.randint(0,h-self.patch),rng.randint(0,w-self.patch)
        c = clean[y:y+self.patch,x:x+self.patch]
        n = noisy[y:y+self.patch,x:x+self.patch]
        if self.augment:
            if rng.getrandbits(1): c,n=np.flip(c,axis=0),np.flip(n,axis=0)
            if rng.getrandbits(1): c,n=np.flip(c,axis=1),np.flip(n,axis=1)
            k = rng.randrange(4)
            c,n=np.rot90(c,k),np.rot90(n,k)
        denominator = 65535.0 if clean.dtype == np.uint16 else 255.0
        to_tensor=lambda a: torch.from_numpy(np.ascontiguousarray(a,dtype=np.float32)/denominator).permute(2,0,1).contiguous()
        return to_tensor(n),to_tensor(c)


def audit(args):
    rows=load_pairs(Path(args.dataset))
    from .data import grouped_split
    groups=grouped_split(rows)
    print(json.dumps({'pairs':len(rows),'groups':len({r['group'] for r in rows}),
                      'split_counts':{k:len(v) for k,v in groups.items()}},indent=2))


def main():
    p=argparse.ArgumentParser(description='Import genuine aligned noisy/clean reference pairs (private/offline)')
    sub=p.add_subparsers(dest='command',required=True)
    a=sub.add_parser('import-pairs')
    a.add_argument('--clean',required=True);a.add_argument('--noisy',required=True)
    a.add_argument('--dataset',required=True);a.add_argument('--group',required=True)
    a.add_argument('--min-side',type=int,default=256)
    a.add_argument('--rights-confirmed',action='store_true');a.set_defaults(func=import_pairs)
    lib=sub.add_parser('import-pair-library')
    lib.add_argument('--input',required=True);lib.add_argument('--dataset',required=True)
    lib.add_argument('--rights-confirmed',action='store_true');lib.add_argument('--min-side',type=int,default=256)
    lib.set_defaults(func=import_pair_library)
    b=sub.add_parser('audit');b.add_argument('--dataset',required=True);b.set_defaults(func=audit)
    args=p.parse_args();args.func(args)

if __name__=='__main__':main()
