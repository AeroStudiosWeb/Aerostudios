"""Offline ONNX/SCUNet holdout comparison and private contact-sheet review.

Does not approve, upload, sign or publish model weights. Run only after training,
then review full-size photos manually in the actual AeroEnhance GUI.
"""
import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
import torch

from .data import CleanCrops, sha256_file
from .model import synthetic_noise, psnr, edge_mae
from .paired import PairedCrops
from .pipeline import get_dataset_splits, set_seed


def session(path):
    import onnxruntime as ort
    p=Path(path)
    if not p.is_file():raise ValueError(f'No ONNX file: {p}')
    s=ort.InferenceSession(str(p),providers=['CPUExecutionProvider'])
    ins=s.get_inputs();outs=s.get_outputs()
    shape = ins[0].shape if len(ins) == 1 else []
    def can_accept(actual, expected):
        return actual == expected or actual is None or actual == -1 or isinstance(actual,str)
    if len(ins)!=1 or len(outs)!=1 or ins[0].type!='tensor(float)' or len(shape)!=4 or not all(can_accept(a,e) for a,e in zip(shape,[1,3,256,256])):
        raise ValueError(f'Model {p} is not a compatible float32 RGB NCHW 256-tile ONNX model')
    return s,ins[0].name,outs[0].name


def run_model(loaded, noisy):
    s,i,o=loaded
    # Comparison is on identical fixed 256px holdout crops, the same input
    # tensor format that AeroEnhance uses on one tile.
    y=s.run([o],{i:noisy[None,:,:,:].astype(np.float32,copy=False)})[0]
    if y.shape != (1,3,256,256) or not np.isfinite(y).all():
        raise ValueError(f'Unexpected model output: {y.shape}')
    return np.clip(y[0],0,1)


def metrics(y, reference):
    a=torch.from_numpy(y)
    b=torch.from_numpy(reference)
    return {'psnr_db':psnr(a,b),'edge_mae':float(edge_mae(a,b))}


def image_for(arr):
    rgb=np.transpose(np.clip(arr,0,1),(1,2,0))
    return Image.fromarray(np.uint8(np.round(rgb*255)),mode='RGB')


def preview_sheet(inputs: dict[str,np.ndarray],path:Path):
    cols=list(inputs)
    sheet=Image.new('RGB',(len(cols)*256,288),(18,25,38))
    canvas=ImageDraw.Draw(sheet)
    for idx,label in enumerate(cols):
        sheet.paste(image_for(inputs[label]),(idx*256,32))
        canvas.text((idx*256+10,10),label,fill=(230,245,255))
    path.parent.mkdir(parents=True,exist_ok=True)
    sheet.save(path)


def compare(args):
    if args.patch != 256:
        raise ValueError('The ONNX model contract requires a 256px patch')
    set_seed(args.seed)
    clean_split,pair_split,dataset_hash=get_dataset_splits(args)
    candidate=session(args.candidate)
    other=session(args.scunet) if args.scunet else None
    sources=[]
    for kind,records in [('synthetic',clean_split['test']),('real-pairs',pair_split['test'])]:
        if kind=='real-pairs' and not records:continue
        dataset=CleanCrops(records,patch=256,augment=False,seed=args.seed) if kind=='synthetic' else PairedCrops(records,patch=256,augment=False,seed=args.seed)
        sources.extend((kind,dataset,i) for i in range(min(len(dataset),args.samples_per_domain)))
    if not sources:
        raise ValueError('No held-out images to compare')
    result=[]
    out=Path(args.output);out.mkdir(parents=True,exist_ok=True)
    for number,(kind,dataset,index) in enumerate(sources):
        if kind=='synthetic':
            clean=dataset[index]
            torch.manual_seed(args.seed + index + 700001)
            noisy=synthetic_noise(clean.unsqueeze(0))[0]
        else:
            noisy,clean=dataset[index]
        c=clean.numpy(); n=noisy.numpy()
        variants={'Noisy input':n,'AeroDenoiseNet':run_model(candidate,n)}
        if other is not None:variants['SCUNet']=run_model(other,n)
        if number < args.preview_count:
            preview_sheet({'Clean reference':c,**variants},out/f'{number+1:03d}-{kind}.png')
        result.append({'domain':kind,'source_index':index,
            'metrics':{name:metrics(y,c) for name,y in variants.items()}})
    summary={'dataset_sha256':dataset_hash,'candidate_sha256':sha256_file(Path(args.candidate)),
        'scunet_sha256':sha256_file(Path(args.scunet)) if args.scunet else None,
        'experimental_only':True,'count':len(result),'results':result}
    for domain in ('synthetic','real-pairs'):
        records=[r for r in result if r['domain']==domain]
        if not records:continue
        summary[domain+'_means']={name:{metric:sum(r['metrics'][name][metric] for r in records)/len(records)
            for metric in ('psnr_db','edge_mae')}
            for name in records[0]['metrics']}
    (out/'comparison.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print('Private comparison ready:',out/'comparison.json')
    print('Contact sheets use reduced 8-bit previews; judge details at 100% in the application. No model published.')


def main():
    p=argparse.ArgumentParser(description='Blind-ish offline comparison on held-out crops')
    p.add_argument('--dataset',required=True);p.add_argument('--paired-dataset')
    p.add_argument('--candidate',required=True);p.add_argument('--scunet')
    p.add_argument('--output',required=True);p.add_argument('--seed',type=int,default=42)
    p.add_argument('--patch',type=int,default=256)
    p.add_argument('--samples-per-domain',type=int,default=20)
    p.add_argument('--preview-count',type=int,default=12)
    args=p.parse_args();compare(args)

if __name__=='__main__':main()
