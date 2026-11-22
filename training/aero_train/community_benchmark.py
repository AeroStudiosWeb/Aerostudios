"""Fixed, independent benchmark for weekly community model candidates.

A candidate NEVER trains on benchmark images. This evaluates incumbent and
candidate on exactly the same generated noise, with group-and-hash isolation.
The test is synthetic; human review of real photographs remains mandatory.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import torch
from .data import load_manifest, CleanCrops, sha256_file
from .model import AeroDenoiseNet, synthetic_noise, psnr, edge_mae
from .pipeline import load_checkpoint, device_for


def compare_metrics(candidate, incumbent, *, min_delta_db=0.15, max_edge_ratio=1.02):
    """Requires absolute synthetic-noise improvement AND non-regression against incumbent."""
    c, i = candidate, incumbent
    if not all(math.isfinite(float(z)) for z in [c['psnr_db'],c['edge_mae'],i['psnr_db'],i['edge_mae'],c['noisy_psnr_db']]):
        return {'passed': False, 'reason': 'Non-finite benchmark metrics'}
    delta=c['psnr_db']-i['psnr_db']
    ratio=c['edge_mae']/max(i['edge_mae'],1e-10)
    gain=c['psnr_db']-c['noisy_psnr_db']
    return {'passed': delta >= min_delta_db and ratio <= max_edge_ratio and gain >= 0.3,
            'psnr_delta_db': round(delta,5), 'edge_error_vs_incumbent': round(ratio,5),
            'synthetic_gain_db': round(gain,5),
            'thresholds': {'min_delta_db':min_delta_db,'max_edge_ratio':max_edge_ratio,'min_gain_db':0.3}}


def evaluate(args):
    if Path(args.candidate).resolve() == Path(args.incumbent).resolve():
        raise ValueError('Candidate and incumbent must be distinct checkpoints')
    evaluation=load_manifest(Path(args.benchmark_dataset)/'manifest.jsonl',verify_hash=True)
    training=load_manifest(Path(args.training_dataset)/'manifest.jsonl',verify_hash=True)
    leak={r['sha256'] for r in evaluation} & {r['sha256'] for r in training}
    if leak:raise ValueError(f'Benchmark leakage: {len(leak)} images also appear in training dataset')
    overlap_groups={r['group'] for r in evaluation} & {r['group'] for r in training}
    if overlap_groups:raise ValueError(f'Benchmark creator/session overlap: {len(overlap_groups)} groups')
    if len(evaluation) < args.min_images or len({r['group'] for r in evaluation}) < 3:
        raise ValueError('Independent benchmark needs >= minimum images across >=3 distinct sessions')
    device=device_for(args.device)
    cp0=load_checkpoint(Path(args.incumbent),device)
    cp1=load_checkpoint(Path(args.candidate),device)
    if (cp0['width'],cp0['depth']) != (cp1['width'],cp1['depth']):
        raise ValueError('Candidate and incumbent model architectures differ')
    models=[]
    for cp in (cp0,cp1):
        m=AeroDenoiseNet(cp['width'],cp['depth']).to(device)
        m.load_state_dict(cp['model']);m.eval();models.append(m)
    sums={'noisy_psnr_db':0.,'incumbent_psnr_db':0.,'candidate_psnr_db':0.,
          'incumbent_edge_mae':0.,'candidate_edge_mae':0.}
    with torch.inference_mode():
        for r in evaluation:
            clean=CleanCrops([r],patch=256,augment=False,seed=41)[0].unsqueeze(0).to(device)
            seed=int(hashlib.sha256(r['sha256'].encode()).hexdigest()[:8],16)
            # Both models must see the exact same noise realization per image.
            with torch.random.fork_rng(devices=[0] if device.type=='cuda' else []):
                torch.manual_seed(seed)
                if device.type=='cuda':torch.cuda.manual_seed_all(seed)
                noisy=synthetic_noise(clean)
            incumbent, candidate=(m(noisy).clamp(0,1) for m in models)
            sums['noisy_psnr_db']+=psnr(noisy,clean)
            sums['incumbent_psnr_db']+=psnr(incumbent,clean)
            sums['candidate_psnr_db']+=psnr(candidate,clean)
            sums['incumbent_edge_mae']+=float(edge_mae(incumbent,clean))
            sums['candidate_edge_mae']+=float(edge_mae(candidate,clean))
    n=len(evaluation)
    a={k:v/n for k,v in sums.items()}
    incumbent={'psnr_db':a['incumbent_psnr_db'],'edge_mae':a['incumbent_edge_mae'],
               'noisy_psnr_db':a['noisy_psnr_db']}
    candidate={'psnr_db':a['candidate_psnr_db'],'edge_mae':a['candidate_edge_mae'],
               'noisy_psnr_db':a['noisy_psnr_db']}
    gate=compare_metrics(candidate,incumbent,min_delta_db=args.min_delta_db,max_edge_ratio=args.max_edge_ratio)
    report={'schema':1,'kind':'community-benchmark','synthetic_only':True,
            'human_review_required':True,'publish_automatically':False,
            'benchmark_images':n,'independent_groups':len({r['group'] for r in evaluation}),
            'benchmark_manifest_sha256':sha256_file(Path(args.benchmark_dataset)/'manifest.jsonl'),
            'training_manifest_sha256':sha256_file(Path(args.training_dataset)/'manifest.jsonl'),
            'candidate_checkpoint_sha256':sha256_file(Path(args.candidate)),
            'incumbent_checkpoint_sha256':sha256_file(Path(args.incumbent)),
            'candidate':candidate,'incumbent':incumbent,'gate':gate}
    target=Path(args.output);target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'benchmark_images':n,'groups':report['independent_groups'],'gate':gate},indent=2))
    if not gate['passed']:
        print('NOT ELIGIBLE FOR PROMOTION. Keep incumbent model. No update has been staged.')


def main():
    p=argparse.ArgumentParser(description='Compare weekly candidate and incumbent on a FROZEN independent benchmark')
    p.add_argument('--candidate',required=True);p.add_argument('--incumbent',required=True)
    p.add_argument('--benchmark-dataset',required=True);p.add_argument('--training-dataset',required=True)
    p.add_argument('--output',required=True);p.add_argument('--device',choices=['cuda','cpu'],default='cuda')
    p.add_argument('--min-images',type=int,default=10)
    p.add_argument('--min-delta-db',type=float,default=0.15)
    p.add_argument('--max-edge-ratio',type=float,default=1.02)
    a=p.parse_args()
    if a.min_images < 10 or a.min_delta_db < 0 or a.max_edge_ratio < 1: p.error('Unsafe quality gate thresholds')
    evaluate(a)

if __name__=='__main__':main()
