import json
import tempfile
import unittest
from pathlib import Path
from argparse import Namespace
import numpy as np
import tifffile
from unittest.mock import patch

from PIL import Image, ImageDraw
import torch

from aero_train.data import grouped_split, load_manifest, check_record, sha256_file
from aero_train.dataset_cli import add_entries, LICENSE, import_clean
from aero_train.data import CleanCrops
from aero_train.model import AeroDenoiseNet, edge_mae, synthetic_noise


class PipelineTests(unittest.TestCase):
    def test_model_contract(self):
        model=AeroDenoiseNet(width=8,depth=3)
        x=torch.rand(1,3,256,256)
        with torch.no_grad(): y=model(x)
        self.assertEqual(y.shape,x.shape)
        self.assertTrue(torch.isfinite(y).all())
        # Zero final residual layer means identical to input at initialization.
        self.assertTrue(torch.equal(x,y))

    def test_noise_and_edge_metric(self):
        torch.manual_seed(1)
        x=torch.rand(2,3,32,32)
        y=synthetic_noise(x)
        self.assertEqual(y.shape,x.shape)
        self.assertTrue(torch.isfinite(y).all())
        self.assertGreater(float(edge_mae(y,x)),0)

    def test_split_group_isolation(self):
        records=[]
        for group in ('a','b','c','d','e','f'):
            records.extend([{'group':group,'path':str(i)} for i in (0,1)])
        parts=grouped_split(records)
        group_sets=[{r['group'] for r in items} for items in parts.values()]
        self.assertFalse(group_sets[0]&group_sets[1])
        self.assertFalse(group_sets[0]&group_sets[2])
        self.assertFalse(group_sets[1]&group_sets[2])

    def test_missing_licence_fails(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'i.png'
            Image.new('RGB',(64,64),(100,130,170)).save(p)
            item={'path':str(p),'sha256':sha256_file(p),'group':'session1','source':'clean-library','license':'none'}
            with self.assertRaisesRegex(ValueError,'permission'):
                check_record(item)

    def test_deleted_and_withdrawn_feedback_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            r=Path(root);image=r/'before.png';meta=r/'metadata.json'
            Image.new('RGB',(64,64)).save(image)
            sha=sha256_file(image)
            meta.write_text(json.dumps({'id':'x','training_permission':True,
                'before_sha256':sha,'with_example':True,'expires_unix':4000000000}))
            item={'path':str(image),'sha256':sha,'group':'session1',
                'source':'feedback','contribution_id':'x','metadata_path':str(meta),'license':LICENSE}
            check_record(item)
            meta.write_text(json.dumps({'id':'x','training_permission':False,
                'before_sha256':sha,'with_example':True,'expires_unix':4000000000}))
            with self.assertRaisesRegex(ValueError,'opt-in'):
                check_record(item)
            meta.unlink()
            with self.assertRaisesRegex(ValueError,'withdrawn'):
                check_record(item)

    def test_sixteen_bit_clean_reference_survives_import_and_training_reader(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            originals = root / 'originals'
            originals.mkdir()
            clean = np.empty((32, 32, 3), dtype=np.uint16)
            clean[:, :, 0] = 12001
            clean[:, :, 1] = 32003
            clean[:, :, 2] = 50007
            tifffile.imwrite(originals / 'clean.tiff', clean, photometric='rgb', metadata=None)
            dataset = root / 'dataset'
            import_clean(Namespace(input=str(originals), dataset=str(dataset),
                                   rights_confirmed=True, group='canon7d-sessionA', min_side=16))
            records = load_manifest(dataset / 'manifest.jsonl')
            self.assertEqual(len(records), 1)
            path = Path(records[0]['path'])
            self.assertEqual(path.suffix, '.tiff')
            self.assertTrue(np.array_equal(tifffile.imread(path), clean))
            tensor = CleanCrops(records, patch=16, augment=False)[0]
            self.assertEqual(tuple(tensor.shape), (3, 16, 16))
            self.assertAlmostEqual(float(tensor[0, 0, 0]), 12001 / 65535, places=7)
            self.assertAlmostEqual(float(tensor[1, 0, 0]), 32003 / 65535, places=7)
            self.assertAlmostEqual(float(tensor[2, 0, 0]), 50007 / 65535, places=7)

    def test_manifest_rejects_duplicates(self):
        with tempfile.TemporaryDirectory() as root:
            r=Path(root);p=r/'a.png';Image.new('RGB',(64,64)).save(p)
            rec={'path':str(p),'sha256':sha256_file(p),'group':'a','source':'clean-library','license':LICENSE}
            (r/'manifest.jsonl').write_text(json.dumps(rec)+'\n'+json.dumps({**rec,'group':'b'})+'\n')
            with self.assertRaisesRegex(ValueError,'Duplicate'):
                load_manifest(r/'manifest.jsonl')


if __name__=='__main__':unittest.main()
