"""Opt-in dataset assembly; never assumes enhanced images are clean truth."""
import argparse
import csv
import json
import os
import re
import shutil
import time
import uuid
from pathlib import Path
from PIL import Image, ImageOps
import tifffile
from .high_precision import read_rgb16_tiff

from .data import sha256_file, load_manifest

SUPPORTED = {'.png','.jpg','.jpeg','.tif','.tiff','.webp','.bmp'}
LICENSE = 'operator-verified-training-permission'


def add_entries(manifest: Path, entries: list[dict]):
    manifest.parent.mkdir(parents=True, exist_ok=True)
    current = []
    if manifest.exists():
        current = [json.loads(x) for x in manifest.read_text(encoding='utf-8').splitlines() if x.strip()]
    existing = {r['sha256'] for r in current}
    added = 0
    for e in entries:
        if e['sha256'] not in existing:
            current.append(e)
            existing.add(e['sha256'])
            added += 1
    tmp = manifest.with_suffix('.tmp')
    tmp.write_text(''.join(json.dumps(x, sort_keys=True)+'\n' for x in current), encoding='utf-8')
    os.replace(tmp, manifest)
    return added


def import_clean(args):
    if not args.rights_confirmed:
        raise ValueError('Explicit --rights-confirmed required; do not import photos you cannot license for training')
    if not args.group.strip() or args.group.lower() in ('unknown','default'):
        raise ValueError('Provide a meaningful photographer/session group (no usernames required)')
    src, dest = Path(args.input), Path(args.dataset)
    if not src.is_dir():
        raise ValueError('Input must be a folder of LICENSED, genuinely clean images')
    dest.mkdir(parents=True,exist_ok=True)
    samples = dest/'clean'
    samples.mkdir(exist_ok=True)
    records = []
    for file in sorted(src.rglob('*')):
        if not file.is_file() or file.is_symlink() or file.suffix.lower() not in SUPPORTED:
            continue
        # Unlike Image.convert('RGB'), preserve uint16 clean reference TIFFs.
        # The 8-bit path remains unchanged for JPEG, normal PNG, etc.
        rgb16 = read_rgb16_tiff(file)
        if rgb16 is not None:
            if min(rgb16.shape[:2]) < args.min_side:
                continue
            new_path = samples/(str(uuid.uuid4())+'.tiff')
            tifffile.imwrite(new_path, rgb16, photometric='rgb', metadata=None)
        else:
            with Image.open(file) as f:
                rgb = ImageOps.exif_transpose(f).convert('RGB')
            if min(rgb.size) < args.min_side:
                continue
            new_path = samples/(str(uuid.uuid4())+'.png')
            rgb.save(new_path, format='PNG')
        # Re-encoded without original filename/EXIF; stored in private dataset.
        sha = sha256_file(new_path)
        records.append({'path':str(new_path.resolve()),'sha256':sha,'group':args.group,
            'source':'clean-library','license':LICENSE})
    n = add_entries(dest/'manifest.jsonl',records)
    print(f'Imported {n} distinct clean reference photos. Dataset: {dest / "manifest.jsonl"}')


def feedback_review(args):
    # Operator can inspect image files locally before editing this table.
    storage=Path(args.feedback_dir)
    if not storage.is_dir(): raise ValueError('Feedback store does not exist')
    rows=[]
    for d in sorted(storage.iterdir()):
        if not d.is_dir() or not re.fullmatch(r'[0-9a-f-]{36}',d.name):continue
        path=d/'metadata.json'
        if not path.is_file(): continue
        try: m=json.loads(path.read_text(encoding='utf-8'))
        except (ValueError,OSError): continue
        if m.get('training_permission') and m.get('with_example') and m.get('expires_unix',0)>time.time() and (d/'before.png').is_file():
            rows.append({'id':d.name,'group':'','clean_confirmed':'NO','license_checked':'NO'})
    out=Path(args.output)
    out.parent.mkdir(parents=True,exist_ok=True)
    with out.open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=['id','group','clean_confirmed','license_checked']);writer.writeheader();writer.writerows(rows)
    print(f'Found {len(rows)} training-opted-in examples. This CSV approves NOTHING until reviewed and changed to YES.')


def curate_feedback(args):
    if not args.curator_confirmation:
        raise ValueError('Explicit --curator-confirmation required')
    feedback=Path(args.feedback_dir).resolve()
    items=[]
    with Path(args.reviewed_csv).open(newline='',encoding='utf-8') as f:
        for row in csv.DictReader(f):
            if row.get('clean_confirmed','').strip().upper() != 'YES' or row.get('license_checked','').strip().upper() != 'YES':
                continue
            item_id=row.get('id','').strip()
            if not re.fullmatch(r'[0-9a-f-]{36}',item_id):
                raise ValueError('Invalid contribution id')
            group=row.get('group','').strip()
            if not group or group.lower() in ('unknown','default'):
                raise ValueError('Curator must group same photographer/session together')
            entry_dir=(feedback/item_id).resolve()
            if entry_dir.parent != feedback:raise ValueError('Bad feedback path')
            meta_path=entry_dir/'metadata.json'
            m=json.loads(meta_path.read_text(encoding='utf-8'))
            if m.get('id')!=item_id or not m.get('training_permission') or m.get('consent_version')!='2026-11-beta-v2-training':
                raise ValueError('Contribution lacks valid v2 training permission: '+item_id)
            if not m.get('with_example') or m['expires_unix']<=time.time():
                raise ValueError('Contribution expired or has no example: '+item_id)
            image_path=entry_dir/'before.png'
            if sha256_file(image_path)!=m['before_sha256']:
                raise ValueError('Contribution content/hash mismatch: '+item_id)
            # Never treat 'after.png' as target. The curator confirms the ORIGINAL
            # preview itself is a genuinely clean reference image.
            items.append({'path':str(image_path),'sha256':m['before_sha256'],
                'metadata_path':str(meta_path),'contribution_id':item_id,
                'group':group,'source':'feedback','license':LICENSE})
    n=add_entries(Path(args.dataset)/'manifest.jsonl',items)
    print(f'Linked {n} reviewed consented examples. Images remain in feedback store; deletion/expiry stops future training.')


def audit(args):
    records=load_manifest(Path(args.dataset)/'manifest.jsonl',verify_hash=True)
    from .data import grouped_split
    split=grouped_split(records)
    print(json.dumps({'count':len(records),'groups':len({x['group'] for x in records}),
                      'splits':{k:len(v) for k,v in split.items()},
                      'feedback':sum(x['source']=='feedback' for x in records)},indent=2))


def main():
    p=argparse.ArgumentParser(description='AeroEnhance private dataset curation')
    sub=p.add_subparsers(dest='cmd',required=True)
    c=sub.add_parser('import-clean',help='Import clean/licensed originals, never model outputs')
    c.add_argument('--input',required=True);c.add_argument('--dataset',required=True)
    c.add_argument('--group',required=True,help='Anonymised photographer/session identifier')
    c.add_argument('--rights-confirmed',action='store_true'); c.add_argument('--min-side',type=int,default=256)
    c.set_defaults(func=import_clean)
    r=sub.add_parser('review-feedback',help='Generate a deny-by-default manual curator CSV')
    r.add_argument('--feedback-dir',required=True);r.add_argument('--output',required=True);r.set_defaults(func=feedback_review)
    r=sub.add_parser('curate-feedback',help='Add curator-confirmed, explicitly licensed clean examples')
    r.add_argument('--feedback-dir',required=True);r.add_argument('--reviewed-csv',required=True)
    r.add_argument('--dataset',required=True);r.add_argument('--curator-confirmation',action='store_true')
    r.set_defaults(func=curate_feedback)
    a=sub.add_parser('audit',help='Reject deleted, expired or unlicensed examples and show group split')
    a.add_argument('--dataset',required=True);a.set_defaults(func=audit)
    args=p.parse_args()
    try:args.func(args)
    except (ValueError, OSError, KeyError) as e:p.error(str(e))

if __name__ == '__main__': main()
