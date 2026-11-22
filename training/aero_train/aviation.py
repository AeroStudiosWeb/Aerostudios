"""Aviation-domain diagnostic, never a publication/holdout quality gate.

Your small aviation collection is NOT used for parameter training here. It is
compared against identical simulated noise for the candidate and SCUNet.
Reviewing repeated runs on the same set can still overfit human decisions.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from .compare import image_for, metrics, preview_sheet, run_model, session
from .data import CleanCrops, load_manifest, sha256_file
from .model import synthetic_noise


def run(args):
    references=load_manifest(Path(args.aviation_dataset)/'manifest.jsonl',verify_hash=True)
    pretrain=load_manifest(Path(args.training_dataset)/'manifest.jsonl',verify_hash=True)
    if {r['sha256'] for r in references} & {r['sha256'] for r in pretrain}:
        raise ValueError('Aviation evaluation contains an image also in the training corpus; remove the overlap')
    if args.limit < 1:raise ValueError('Limit must be positive')
    loaded=session(args.candidate)
    scunet=session(args.scunet) if args.scunet else None
    out=Path(args.output);out.mkdir(parents=True,exist_ok=True)
    result=[]
    for i, reference in enumerate(references[:args.limit]):
        clean=CleanCrops([reference],patch=256,augment=False,seed=41)[0]
        seed=int(hashlib.sha256(reference['sha256'].encode()).hexdigest()[:8],16)
        with torch.random.fork_rng(devices=[]):
            torch.manual_seed(seed)
            noisy=synthetic_noise(clean.unsqueeze(0))[0]
        c=clean.numpy();n=noisy.numpy()
        variants={'Noisy input':n,'AeroDenoiseNet':run_model(loaded,n)}
        if scunet is not None:variants['SCUNet']=run_model(scunet,n)
        if i < args.preview_count:
            preview_sheet({'Clean reference':c,**variants},out/f'aviation-{i+1:03d}.png')
        result.append({'photo_sha256':reference['sha256'],'group':reference['group'],
            'scores':{name:metrics(value,c) for name,value in variants.items()}})
    if not result:raise ValueError('Aviation dataset contains no records')
    model_names=list(result[0]['scores'])
    averages={name:{metric:sum(r['scores'][name][metric] for r in result)/len(result)
        for metric in ('psnr_db','edge_mae')} for name in model_names}
    summary={'kind':'aviation-domain-diagnostic','is_release_gate':False,
        'evaluation_uses_training_corpus':False,'synthetic_noise_only':True,
        'note':'Tiny aviation sample; cannot prove real high-ISO performance. No model was fine-tuned on aviation photos. Repeated iterative selection on this set can bias decisions.',
        'photos':len(result),'groups':len({r['group'] for r in result}),
        'candidate_sha256':sha256_file(Path(args.candidate)),
        'scunet_sha256':sha256_file(Path(args.scunet)) if args.scunet else None,
        'means':averages,'samples':result}
    (out/'aviation-report.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(json.dumps({'photos':summary['photos'],'groups':summary['groups'],'means':averages,
                      'status':'DIAGNOSTIC ONLY; no model approved'},indent=2))


def main():
    p=argparse.ArgumentParser(description='Separate diagnostic of aviation-photo detail, not training')
    p.add_argument('--aviation-dataset',required=True)
    p.add_argument('--training-dataset',required=True)
    p.add_argument('--candidate',required=True)
    p.add_argument('--scunet')
    p.add_argument('--output',required=True)
    p.add_argument('--limit',type=int,default=60)
    p.add_argument('--preview-count',type=int,default=18)
    run(p.parse_args())

if __name__=='__main__':main()
