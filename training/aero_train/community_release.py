"""Fail-closed staging of human-approved, signed-feed-compatible candidates.

Never signs, publishes, uploads, or activates a model. A staging manifest is
unsigned and cannot be installed as a trusted automatic update.
"""
import argparse
import hashlib
import json
import re
import time
from pathlib import Path
from urllib.parse import urlsplit


def filehash(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def evaluate_release(benchmark,validation,heldout,model,confirmation,version,url):
    if confirmation!='I REVIEWED THE IMAGES AND APPROVE THIS CANDIDATE':
        raise ValueError('Explicit independent human-image-review confirmation required')
    if benchmark.get('schema')!=1 or not benchmark.get('gate',{}).get('passed'):
        raise ValueError('Fixed benchmark failed or absent')
    if benchmark.get('synthetic_only') is not True or benchmark.get('human_review_required') is not True:
        raise ValueError('Unexpected benchmark provenance')
    if benchmark.get('benchmark_images',0)<10 or benchmark.get('independent_groups',0)<3:
        raise ValueError('Insufficient benchmark independence')
    if heldout.get('automatic_gate_passed') is not True:
        raise ValueError('Training held-out gate failed')
    if validation.get('sha256','').lower()!=filehash(model):
        raise ValueError('ONNX file differs from validated export')
    if validation.get('checkpoint_sha256')!=heldout.get('checkpoint_sha256') or \
       validation.get('checkpoint_sha256')!=benchmark.get('candidate_checkpoint_sha256'):
        raise ValueError('Candidate checkpoint hashes do not agree across evaluation and export')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?',version):
        raise ValueError('Invalid semantic model version')
    u=urlsplit(url)
    if u.scheme!='https' or not u.netloc or u.username or u.password or u.fragment:
        raise ValueError('A public model download URL must use HTTPS')
    if not url.lower().endswith('.onnx'):
        raise ValueError('Model URL must end in .onnx')
    if Path(model).stat().st_size==0 or Path(model).stat().st_size>3*1024**3:
        raise ValueError('Model outside allowed size')
    return {'schema':1,'channel':'beta','model_id':'aero-denoise','version':version,
            'file_name':'aero-denoise.onnx','url':url,'size_bytes':Path(model).stat().st_size,
            'sha256':filehash(model),'min_app_version':'0.7.0-beta.1',
            'expires_unix':int(time.time())+14*24*3600,
            'notes':'Human-reviewed community denoiser candidate; independent benchmark passed',
            'latest_app_version':None,'app_release_url':None}


def main():
    p=argparse.ArgumentParser(description='Stage an unsigned update manifest only after independent reviews')
    p.add_argument('--benchmark',required=True);p.add_argument('--heldout',required=True)
    p.add_argument('--model',required=True);p.add_argument('--validation',required=True)
    p.add_argument('--version',required=True);p.add_argument('--url',required=True)
    p.add_argument('--confirm',required=True);p.add_argument('--output',required=True)
    a=p.parse_args()
    b=json.loads(Path(a.benchmark).read_text(encoding='utf-8'))
    h=json.loads(Path(a.heldout).read_text(encoding='utf-8'))
    v=json.loads(Path(a.validation).read_text(encoding='utf-8'))
    manifest=evaluate_release(b,v,h,Path(a.model),a.confirm,a.version,a.url)
    target=Path(a.output);target.parent.mkdir(parents=True,exist_ok=True)
    if target.exists():raise ValueError('Existing staged manifest not overwritten; use a new version')
    target.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(f'STAGED, UNSIGNED: {target}. Nothing was published; use the offline Ed25519 signer and deploy manually.')

if __name__=='__main__':main()
