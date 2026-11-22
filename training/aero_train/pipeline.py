"""Train/evaluate/export an AeroEnhance model. NO AUTOMATIC PUBLISHING.

Training requires clean licensed references. User ratings and AeroEnhance's own
processed output are NOT target labels. Every model is gated on held-out GROUPS.
"""
import argparse
import hashlib
import json
import math
import os
import random
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from .data import CleanCrops, grouped_split, load_manifest, sha256_file
from .model import AeroDenoiseNet, edge_mae, psnr, synthetic_noise
from .paired import PairedCrops, load_pairs

SCHEMA_VERSION='0.7-training-v3'


def device_for(s):
    if s == 'cuda' and not torch.cuda.is_available():
        raise RuntimeError('CUDA PyTorch not available. Install GPU-enabled PyTorch from pytorch.org or use --device cpu for a smoke test.')
    d=torch.device('cuda:0' if s=='cuda' else 'cpu')
    if d.type=='cuda':
        print('GPU:',torch.cuda.get_device_name(0))
        torch.backends.cudnn.benchmark=True
    return d


def set_seed(seed):
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
    if torch.cuda.is_available():torch.cuda.manual_seed_all(seed)


def immutable_dataset_snapshot(path):
    records=load_manifest(path,verify_hash=True)
    split=grouped_split(records)
    # Version + assignment bytes ensure old checkpoint split decisions cannot
    # accidentally resume under the new balanced grouping policy.
    assignments=sorted((part, r['group'], r['sha256']) for part, items in split.items() for r in items)
    fingerprint=hashlib.sha256(json.dumps((SCHEMA_VERSION, assignments)).encode()).hexdigest()
    return records,split,fingerprint


def get_dataset_splits(args):
    """Split clean + optional paired images TOGETHER by session to prevent leakage."""
    clean, old_split, old_hash = immutable_dataset_snapshot(Path(args.dataset) / 'manifest.jsonl')
    if not getattr(args, 'paired_dataset', None):
        return old_split, {k: [] for k in ('train', 'val', 'test')}, old_hash
    paired = load_pairs(Path(args.paired_dataset), verify_hash=True)
    tagged = [dict(x, _kind='clean') for x in clean] + [dict(x, _kind='pair') for x in paired]
    merged = grouped_split(tagged)
    clean_split = {k:[r for r in v if r['_kind']=='clean'] for k,v in merged.items()}
    pair_split = {k:[r for r in v if r['_kind']=='pair'] for k,v in merged.items()}
    if any(not clean_split[k] for k in ('train','val','test')):
        raise ValueError('Joint group split has an empty clean split. Add independent clean sessions; do not reuse a held-out session for training.')
    if not pair_split['train']:
        raise ValueError('Joint group split has no TRAIN aligned pairs. Add more pair groups.')
    fingerprint = hashlib.sha256(json.dumps((SCHEMA_VERSION, sorted(
        (part, r['_kind'],r['group'],r.get('sha256',r.get('clean_sha256')),
         r.get('noisy_sha256','')) for part, items in merged.items() for r in items)),sort_keys=True).encode()).hexdigest()
    return clean_split, pair_split, fingerprint


def make_pair_loader(items, patch, batch, augment, seed):
    return DataLoader(PairedCrops(items,patch=patch,augment=augment,seed=seed),
        batch_size=batch,shuffle=augment,num_workers=0,pin_memory=torch.cuda.is_available())


def validate_pairs(model, loader, device):
    model.eval()
    stats={'baseline_psnr':0.,'model_psnr':0.,'baseline_edge_mae':0.,'model_edge_mae':0.,'count':0}
    with torch.inference_mode():
        for noisy,clean in loader:
            noisy,clean=noisy.to(device),clean.to(device)
            restored=model(noisy).clamp(0,1)
            count=clean.shape[0]
            for name,tensor in [('baseline',noisy),('model',restored)]:
                stats[f'{name}_psnr']+=psnr(tensor,clean)*count
                stats[f'{name}_edge_mae']+=float(edge_mae(tensor,clean))*count
            stats['count']+=count
    if not stats['count']:raise ValueError('No aligned-pair validation examples')
    for key in ('baseline_psnr','model_psnr','baseline_edge_mae','model_edge_mae'):
        stats[key]/=stats['count']
    stats['psnr_gain_db']=stats['model_psnr']-stats['baseline_psnr']
    stats['edge_error_ratio']=stats['model_edge_mae']/max(stats['baseline_edge_mae'],1e-10)
    return stats

def make_loader(items, patch, batch, augment, workers, seed):
    return DataLoader(CleanCrops(items,patch=patch,augment=augment,seed=seed),
        batch_size=batch,shuffle=augment,num_workers=workers,pin_memory=torch.cuda.is_available(),drop_last=False)


def validate(model,loader,device,seed=19,max_batches=None):
    model.eval()
    report={'baseline_psnr':0.0,'model_psnr':0.0,'baseline_edge_mae':0.0,'model_edge_mae':0.0,'count':0}
    # Training RNG must not change based on evaluation frequency.
    with torch.random.fork_rng(devices=[device.index or 0] if device.type=='cuda' else []):
        torch.manual_seed(seed)
        if device.type=='cuda':torch.cuda.manual_seed_all(seed)
        with torch.inference_mode():
            for i,clean in enumerate(loader):
                if max_batches is not None and i>=max_batches:break
                clean=clean.to(device,non_blocking=True)
                noisy=synthetic_noise(clean)
                restored=model(noisy).clamp(0,1)
                n=clean.size(0)
                report['baseline_psnr']+=psnr(noisy,clean)*n
                report['model_psnr']+=psnr(restored,clean)*n
                report['baseline_edge_mae']+=float(edge_mae(noisy,clean))*n
                report['model_edge_mae']+=float(edge_mae(restored,clean))*n
                report['count']+=n
    if not report['count']:raise ValueError('Validation loader produced no samples')
    for k in ('baseline_psnr','model_psnr','baseline_edge_mae','model_edge_mae'):
        report[k]/=report['count']
    report['psnr_gain_db']=report['model_psnr']-report['baseline_psnr']
    return report


def atomic_torch_save(obj,path):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.part')
    torch.save(obj,tmp)
    os.replace(tmp,path)


def load_checkpoint(path,device='cpu'):
    # Only load locally produced checkpoints. weights_only protects against
    # Python object deserialization in newer PyTorch releases.
    data=torch.load(path,map_location=device,weights_only=True)
    if data.get('schema')!=SCHEMA_VERSION:raise ValueError('Invalid AeroEnhance checkpoint schema')
    return data


def train(args):
    set_seed(args.seed)
    device=device_for(args.device)
    splits,pair_splits,fingerprint=get_dataset_splits(args)
    if len(splits['train'])<args.min_train_images:
        raise ValueError(f'Only {len(splits["train"])} training images. Need at least {args.min_train_images}; use --min-train-images 1 ONLY for private smoke tests.')
    out=Path(args.output)
    out.mkdir(parents=True,exist_ok=True)
    train_loader=make_loader(splits['train'],args.patch,args.batch,True,args.workers,args.seed)
    val_loader=make_loader(splits['val'],args.patch,1,False,0,args.seed)
    paired_loader = make_pair_loader(pair_splits['train'],args.patch,args.batch,True,args.seed) if pair_splits['train'] else None
    paired_val_loader = make_pair_loader(pair_splits['val'],args.patch,1,False,args.seed) if pair_splits['val'] else None
    model=AeroDenoiseNet(args.width,args.depth).to(device)
    optimizer=torch.optim.AdamW(model.parameters(),lr=args.lr,weight_decay=1e-4)
    scaler=torch.amp.GradScaler('cuda',enabled=device.type=='cuda' and args.amp)
    epoch_start=1;best_score=-1e9
    hist=[]
    if args.resume and getattr(args, 'init_checkpoint', None):
        raise ValueError('Choose --resume for same-data continuation OR --init-checkpoint for a new curated dataset')
    if getattr(args, 'init_checkpoint', None):
        source=load_checkpoint(Path(args.init_checkpoint),device)
        if source['width'] != args.width or source['depth'] != args.depth:
            raise ValueError('Incumbent checkpoint architecture differs from candidate')
        model.load_state_dict(source['model'])
        print(f'Initialized from previous model {args.init_checkpoint}; optimizer and best score reset for the new dataset')
    if args.resume:
        cp=load_checkpoint(Path(args.resume),device)
        if cp['dataset_sha256']!=fingerprint:raise ValueError('Dataset changed since checkpoint; refusing unsafe resume')
        if cp['width']!=args.width or cp['depth']!=args.depth:raise ValueError('Model architecture changed')
        model.load_state_dict(cp['model']);optimizer.load_state_dict(cp['optimizer'])
        epoch_start=int(cp['epoch'])+1;best_score=float(cp['best_val_psnr'])
        history_file=out/'training-history.json'
        if history_file.is_file():
            old_history=json.loads(history_file.read_text(encoding='utf-8'))
            if old_history.get('dataset_sha256')==fingerprint:
                hist=[x for x in old_history.get('history',[]) if int(x.get('epoch',0)) < epoch_start]
        if epoch_start>args.epochs:
            raise ValueError(f'Checkpoint is already at epoch {epoch_start-1}; increase --epochs to resume')
    print(f'Training images: {len(splits["train"])} clean + {len(pair_splits["train"])} aligned pairs | Val: {len(splits["val"])} | Held-out TEST: {len(splits["test"])}')
    for epoch in range(epoch_start,args.epochs+1):
        model.train(); losses=[]
        iterator=iter(train_loader)
        paired_iterator=iter(paired_loader) if paired_loader is not None else None
        for step in range(args.steps_per_epoch):
            use_pair=paired_loader is not None and step % args.paired_frequency == 0
            if use_pair:
                try:noisy,clean=next(paired_iterator)
                except StopIteration:
                    paired_iterator=iter(paired_loader);noisy,clean=next(paired_iterator)
                clean=clean.to(device,non_blocking=True)
                noisy=noisy.to(device,non_blocking=True)
            else:
                try:clean=next(iterator)
                except StopIteration:
                    iterator=iter(train_loader);clean=next(iterator)
                clean=clean.to(device,non_blocking=True)
                noisy=synthetic_noise(clean)
            optimizer.zero_grad(set_to_none=True)
            with torch.autocast(device_type=device.type,enabled=device.type=='cuda' and args.amp):
                pred=model(noisy)
                # Give edge retention explicit weight (lettering, panel lines).
                loss=(pred-clean).abs().mean()+0.15*edge_mae(pred,clean)
            if not torch.isfinite(loss):raise RuntimeError('Nonfinite training loss')
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(),1.0)
            scaler.step(optimizer);scaler.update()
            losses.append(float(loss.item()))
        report=validate(model,val_loader,device,seed=1000,max_batches=args.val_batches)
        pair_report=validate_pairs(model,paired_val_loader,device) if paired_val_loader is not None else None
        score=(report['model_psnr']+pair_report['model_psnr'])/2 if pair_report else report['model_psnr']
        print(f'Epoch {epoch}/{args.epochs}: loss={sum(losses)/len(losses):.5f} validation score={score:.3f}dB | synthetic gain={report["psnr_gain_db"]:.3f}dB'+(f' | paired gain={pair_report["psnr_gain_db"]:.3f}dB' if pair_report else ''))
        snapshot={'schema':SCHEMA_VERSION,'epoch':epoch,'model':model.state_dict(),
                  'optimizer':optimizer.state_dict(),'width':args.width,'depth':args.depth,
                  'patch':args.patch,'dataset_sha256':fingerprint,'best_val_psnr':max(best_score,score),'seed':args.seed}
        atomic_torch_save(snapshot,out/'last.pt')
        if score>best_score:
            best_score=score
            atomic_torch_save(snapshot,out/'best.pt')
        hist.append({'epoch':epoch,'loss':sum(losses)/len(losses),'synthetic':report,'paired':pair_report})
        (out/'training-history.json').write_text(json.dumps({'schema':SCHEMA_VERSION,
            'dataset_sha256':fingerprint,'training_records':len(splits['train']),
            'validation_records':len(splits['val']),'test_records':len(splits['test']),'paired_train_records':len(pair_splits['train']),
            'paired_test_records':len(pair_splits['test']),'device':str(device),'history':hist},indent=2),encoding='utf-8')
    print('Saved best checkpoint:',out/'best.pt')
    print('TEST split has NOT been used for model selection. Run evaluate separately.')


def evaluate(args):
    if args.split != 'test':raise ValueError('Only held-out TEST evaluation may gate a release')
    set_seed(args.seed)
    device=device_for(args.device)
    splits,pair_splits,fingerprint=get_dataset_splits(args)
    checkpoint=load_checkpoint(Path(args.checkpoint),device)
    if fingerprint!=checkpoint['dataset_sha256']:raise ValueError('Dataset drift; evaluation rejected')
    model=AeroDenoiseNet(checkpoint['width'],checkpoint['depth']).to(device)
    model.load_state_dict(checkpoint['model'])
    loader=make_loader(splits['test'],args.patch,1,False,0,args.seed)
    report=validate(model,loader,device,seed=20261121)
    pair_report=validate_pairs(model,make_pair_loader(pair_splits['test'],args.patch,1,False,args.seed),device) if pair_splits['test'] else None
    report.update({'schema':SCHEMA_VERSION,'checkpoint_sha256':sha256_file(Path(args.checkpoint)),
        'dataset_sha256':fingerprint,'split':'test','holdout_groups':len({x['group'] for x in splits['test']}),
        'test_images':len(splits['test']),'patch':args.patch,
        'min_psnr_gain_db':args.min_psnr_gain_db,'max_edge_ratio':args.max_edge_ratio})
    edge_ratio=report['model_edge_mae']/max(report['baseline_edge_mae'],1e-10)
    report['edge_error_ratio']=edge_ratio
    report['paired_holdout']=pair_report
    report['minimum_paired_test_images']=args.min_paired_test_images
    report['automatic_gate_passed']=(math.isfinite(report['psnr_gain_db'])
        and report['psnr_gain_db']>=args.min_psnr_gain_db
        and math.isfinite(edge_ratio) and edge_ratio<=args.max_edge_ratio
        and report['test_images']>=args.min_test_images
        and (not getattr(args,'paired_dataset',None) or (pair_report is not None
             and pair_report['count']>=args.min_paired_test_images
             and pair_report['psnr_gain_db']>=args.min_real_psnr_gain_db
             and pair_report['edge_error_ratio']<=args.max_edge_ratio)))
    report['requires_human_blind_review']=True
    out=Path(args.output);out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    if not report['automatic_gate_passed']:
        print('Model did not meet the promotion gate. Keep it private; continue training/data review.')


def export(args):
    checkpoint=load_checkpoint(Path(args.checkpoint))
    model=AeroDenoiseNet(checkpoint['width'],checkpoint['depth'])
    model.load_state_dict(checkpoint['model']);model.eval()
    dest=Path(args.output);dest.parent.mkdir(parents=True,exist_ok=True)
    dummy=torch.rand(1,3,256,256,dtype=torch.float32)
    # Fixed 256x256 is required by apps/aeroenhance/src/ai.rs.
    # Legacy exporter is intentional for stable opset17 Conv/ReLU/Sub graph.
    torch.onnx.export(model,(dummy,),str(dest),export_params=True,dynamo=False,
        opset_version=17,input_names=['input'],output_names=['output'],do_constant_folding=True)
    import onnx
    onnx.checker.check_model(str(dest))
    import onnxruntime as ort
    session=ort.InferenceSession(str(dest),providers=['CPUExecutionProvider'])
    inputs=session.get_inputs();outputs=session.get_outputs()
    if len(inputs)!=1 or len(outputs)!=1 or inputs[0].name!='input' or outputs[0].name!='output':
        raise RuntimeError('ONNX input/output contract mismatch')
    if inputs[0].shape!=[1,3,256,256]:raise RuntimeError(f'Invalid static ONNX input shape: {inputs[0].shape}')
    with torch.no_grad():expect=model(dummy).numpy()
    got=session.run(['output'],{'input':dummy.numpy()})[0]
    delta=np.abs(expect-got).max()
    if got.shape!=(1,3,256,256) or not np.isfinite(got).all() or delta>2e-4:
        dest.unlink(missing_ok=True)
        raise RuntimeError(f'ONNX Runtime equivalence failed: shape={got.shape}, max_diff={delta}')
    details={'onnx':str(dest.resolve()),'sha256':sha256_file(dest),'bytes':dest.stat().st_size,
        'input_shape':[1,3,256,256],'output_shape':[1,3,256,256],
        'float32_max_difference':float(delta),'checkpoint_sha256':sha256_file(Path(args.checkpoint)),
        'schema':SCHEMA_VERSION,'architecture':'AeroDenoiseNet'}
    Path(str(dest)+'.validation.json').write_text(json.dumps(details,indent=2),encoding='utf-8')
    print(json.dumps(details,indent=2))


def candidate(args):
    """Prepare an unsigned manifest; signing and publishing remain manual."""
    import re
    if args.confirm != 'I HAVE REVIEWED THE HELD-OUT IMAGES':
        raise ValueError('Manual human-review confirmation required; use --confirm "I HAVE REVIEWED THE HELD-OUT IMAGES"')
    ev=json.loads(Path(args.evaluation).read_text(encoding='utf-8'))
    validation=json.loads(Path(str(args.model)+'.validation.json').read_text(encoding='utf-8'))
    if not ev.get('automatic_gate_passed') or ev.get('split')!='test':
        raise ValueError('Held-out quality gate has not passed')
    if ev['checkpoint_sha256']!=validation['checkpoint_sha256']:
        raise ValueError('ONNX model was not exported from evaluated checkpoint')
    if validation['sha256']!=sha256_file(Path(args.model)):
        raise ValueError('ONNX bytes changed since verification')
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,100}',args.version):
        raise ValueError('Invalid model version')
    if not args.url.startswith('https://'):
        raise ValueError('Public model URL must be HTTPS')
    from urllib.parse import urlparse
    parsed=urlparse(args.url)
    if parsed.username or parsed.password or not parsed.netloc or parsed.fragment:
        raise ValueError('Invalid model URL')
    manifest={'schema':1,'channel':'beta','model_id':'aero-denoise',
        'version':args.version,'file_name':Path(args.model).name,'url':args.url,
        'size_bytes':Path(args.model).stat().st_size,'sha256':validation['sha256'],
        'min_app_version':'0.7.0-beta.1','expires_unix':int(time.time())+args.valid_days*86400,
        'notes':'Experimental AeroDenoiseNet; opt-in beta model with human-reviewed held-out gate',
        'latest_app_version':None,'app_release_url':None}
    out=Path(args.output);out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print('Unsigned release candidate:',out)
    print('Still required: offline Ed25519 signing, trusted download hosting, manual publish.')


def main():
    parser=argparse.ArgumentParser(description='AeroEnhance GPU training and secure model release candidate pipeline')
    sub=parser.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('train')
    p.add_argument('--dataset',required=True);p.add_argument('--output',required=True)
    p.add_argument('--device',choices=['cuda','cpu'],default='cuda')
    p.add_argument('--epochs',type=int,default=20);p.add_argument('--batch',type=int,default=4)
    p.add_argument('--steps-per-epoch',type=int,default=200);p.add_argument('--val-batches',type=int,default=50)
    p.add_argument('--patch',type=int,choices=[64,128,256],default=128)
    p.add_argument('--width',type=int,default=48);p.add_argument('--depth',type=int,default=7)
    p.add_argument('--lr',type=float,default=2e-4);p.add_argument('--seed',type=int,default=42)
    p.add_argument('--workers',type=int,default=0);p.add_argument('--amp',action=argparse.BooleanOptionalAction,default=True)
    p.add_argument('--resume');p.add_argument('--init-checkpoint',help='Fine-tune from reviewed previous model weights on a NEW curated dataset; reset optimizer')
    p.add_argument('--min-train-images',type=int,default=20)
    p.add_argument('--paired-dataset',help='Optional curated real, aligned noisy/clean pairs')
    p.add_argument('--paired-frequency',type=int,default=3,help='Train on a real pair every N steps')
    p.set_defaults(func=train)
    p=sub.add_parser('evaluate')
    p.add_argument('--dataset',required=True);p.add_argument('--checkpoint',required=True)
    p.add_argument('--device',choices=['cuda','cpu'],default='cuda');p.add_argument('--output',required=True)
    p.add_argument('--split',choices=['test'],default='test');p.add_argument('--patch',type=int,choices=[64,128,256],default=256)
    p.add_argument('--seed',type=int,default=42);p.add_argument('--min-psnr-gain-db',type=float,default=0.3)
    p.add_argument('--paired-dataset',help='Same paired dataset used at training')
    p.add_argument('--min-paired-test-images',type=int,default=10)
    p.add_argument('--min-real-psnr-gain-db',type=float,default=0.1)
    p.add_argument('--max-edge-ratio',type=float,default=1.05);p.add_argument('--min-test-images',type=int,default=10)
    p.set_defaults(func=evaluate)
    p=sub.add_parser('export')
    p.add_argument('--checkpoint',required=True);p.add_argument('--output',required=True);p.set_defaults(func=export)
    p=sub.add_parser('candidate')
    p.add_argument('--model',required=True);p.add_argument('--evaluation',required=True)
    p.add_argument('--version',required=True);p.add_argument('--url',required=True)
    p.add_argument('--output',required=True);p.add_argument('--confirm',required=True)
    p.add_argument('--valid-days',type=int,default=30);p.set_defaults(func=candidate)
    args=parser.parse_args()
    if args.cmd=='train' and (args.epochs<1 or args.batch<1 or args.steps_per_epoch<1 or args.val_batches<1 or args.paired_frequency<1):parser.error('Training counts must be positive')
    if args.cmd=='candidate' and not (1<=args.valid_days<=180):parser.error('valid-days must be 1..180')
    args.func(args)

if __name__ == '__main__': main()
