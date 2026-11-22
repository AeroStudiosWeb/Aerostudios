"""Synchronise opt-in feedback review CSV without losing human decisions.

Only active, non-expired v2 submissions with separate training permission
are included. Deleted/withdrawn examples disappear from the next review.
This command DOES NOT approve examples.
"""
import argparse
import csv
import json
import os
import re
import time
from pathlib import Path

FIELDS=('id','group','clean_confirmed','license_checked')


def active_entries(feedback_dir,now=None):
    now=time.time() if now is None else now
    for d in sorted(Path(feedback_dir).iterdir()):
        if not d.is_dir() or d.is_symlink() or not re.fullmatch(r'[a-f0-9-]{36}',d.name):continue
        try:
            m=json.loads((d/'metadata.json').read_text(encoding='utf-8'))
        except (ValueError, OSError):continue
        if (m.get('id')==d.name and m.get('consent_version')=='2026-11-beta-v2-training'
            and m.get('training_permission') is True and m.get('with_example') is True
            and m.get('expires_unix',0)>now and (d/'before.png').is_file()
            and not (d/'before.png').is_symlink()):
            yield d.name


def sync(feedback_dir,review_csv,now=None):
    feedback_dir=Path(feedback_dir)
    review_csv=Path(review_csv)
    if not feedback_dir.is_dir():raise ValueError('Feedback directory missing')
    old={}
    if review_csv.exists():
        with review_csv.open(newline='',encoding='utf-8-sig') as f:
            for row in csv.DictReader(f):
                if row.get('id'):old[row['id']]=row
    rows=[]
    for identity in active_entries(feedback_dir,now=now):
        row=old.get(identity,{})
        rows.append({'id':identity,'group':row.get('group',''),
                     'clean_confirmed':row.get('clean_confirmed','NO'),
                     'license_checked':row.get('license_checked','NO')})
    review_csv.parent.mkdir(parents=True,exist_ok=True)
    tmp=review_csv.with_suffix(review_csv.suffix+'.tmp')
    with tmp.open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=FIELDS)
        writer.writeheader();writer.writerows(rows)
    os.replace(tmp,review_csv)
    return {'active':len(rows),'new':sum(r['id'] not in old for r in rows),
            'approved':sum(str(r['clean_confirmed']).strip().upper()=='YES' and str(r['license_checked']).strip().upper()=='YES' for r in rows)}


def main():
    p=argparse.ArgumentParser(description='Merge new candidate feedback into existing DENY-by-default curator CSV')
    p.add_argument('--feedback-dir',required=True);p.add_argument('--output',required=True)
    a=p.parse_args()
    print(json.dumps(sync(a.feedback_dir,a.output),indent=2))

if __name__=='__main__':main()
