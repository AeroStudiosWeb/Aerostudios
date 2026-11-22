import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

import numpy as np
from PIL import Image

from aero_train.paired import import_pairs, load_pairs, PairedCrops
from aero_train.dataset_cli import import_clean
from aero_train.pipeline import get_dataset_splits, validate_pairs
from aero_train.model import AeroDenoiseNet
from torch.utils.data import DataLoader
import torch


class PairedDatasetTests(unittest.TestCase):
    def test_matched_pair_import_augmentation_and_integrity(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp);c=base/'clean';n=base/'noisy'
            c.mkdir();n.mkdir()
            clean=np.zeros((64,64,3),dtype=np.uint8)
            clean[10:40,15:50]=[128,200,70]
            noisy=np.minimum(clean.astype(np.int16)+3,255).astype(np.uint8)
            Image.fromarray(clean).save(c/'plane.png')
            Image.fromarray(noisy).save(n/'plane.png')
            args=Namespace(clean=str(c),noisy=str(n),dataset=str(base/'pairs'),group='session-a',
                           rights_confirmed=True,min_side=64)
            import_pairs(args)
            rows=load_pairs(base/'pairs')
            self.assertEqual(len(rows),1)
            pair=PairedCrops(rows,patch=64,augment=False)
            a,b=pair[0]
            self.assertEqual(tuple(a.shape),(3,64,64))
            self.assertAlmostEqual(float(b[0,20,20]),128/255,places=5)
            self.assertAlmostEqual(float(a[0,20,20]),131/255,places=5)
            self.assertGreater(float((a-b).abs().mean()),0)
            Image.new('RGB',(64,64),'red').save(rows[0]['noisy_path'])
            with self.assertRaisesRegex(ValueError,'changed'):
                _=pair[0]

    def test_refuses_unmatched_stems_and_missing_consent(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp);c=base/'c';n=base/'n';c.mkdir();n.mkdir()
            Image.new('RGB',(64,64)).save(c/'a.png')
            Image.new('RGB',(64,64)).save(n/'b.png')
            args=Namespace(clean=str(c),noisy=str(n),dataset=str(base/'data'),group='group',
                           rights_confirmed=True,min_side=64)
            with self.assertRaisesRegex(ValueError,'unmatched'):
                import_pairs(args)
            args.rights_confirmed=False
            with self.assertRaisesRegex(ValueError,'rights-confirmed'):
                import_pairs(args)

    def test_joint_split_and_training_cpu_smoke(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp);clean_dataset=base/'clean-dataset';paired_dataset=base/'paired-dataset'
            for group in ('session01','session02','session03','session04'):
                c=base/f'{group}-clean';n=base/f'{group}-noisy';c.mkdir();n.mkdir()
                clean=np.random.default_rng(len(group)+int(group[-1])).integers(40,220,(64,64,3),dtype=np.uint8)
                noisy=np.minimum(clean.astype(np.int16)+4,255).astype(np.uint8)
                Image.fromarray(clean).save(c/'photo.png')
                Image.fromarray(noisy).save(n/'photo.png')
                import_clean(Namespace(input=str(c),dataset=str(clean_dataset),group=group,
                                      rights_confirmed=True,min_side=64))
                import_pairs(Namespace(clean=str(c),noisy=str(n),dataset=str(paired_dataset),
                                       group=group,rights_confirmed=True,min_side=64))
            args=Namespace(dataset=str(clean_dataset),paired_dataset=str(paired_dataset))
            clean,pairs,hash_=get_dataset_splits(args)
            self.assertEqual(sum(len(v) for v in clean.values()),4)
            self.assertEqual(sum(len(v) for v in pairs.values()),4)
            for a in ('train','val','test'):
                self.assertEqual({r['group'] for r in clean[a]}, {r['group'] for r in pairs[a]})
                self.assertTrue(clean[a])
            loader=DataLoader(PairedCrops(pairs['test'],patch=64,augment=False),batch_size=1)
            report=validate_pairs(AeroDenoiseNet(width=8,depth=3),loader,torch.device('cpu'))
            self.assertEqual(report['count'],len(pairs['test']))
            self.assertAlmostEqual(report['psnr_gain_db'],0,places=5)
            self.assertTrue(len(hash_)==64)

if __name__=='__main__':unittest.main()
