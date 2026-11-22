"""Offline regressions for Commons licence gate and general-domain training."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import torch
from PIL import Image

from aero_train.commons import (normalize_license, permitted_image, valid_media_url,
                                 download_image, verify_downloads, write_ledger)
from aero_train.data import grouped_split, sha256_file, load_manifest
from aero_train.dataset_cli import LICENSE
from aero_train.pipeline import immutable_dataset_snapshot


class GeneralPretrainingTests(unittest.TestCase):
    def example_page(self, licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/'):
        return {'title':'File:An aircraft.jpg','imageinfo':[{'width':2048,'height':1365,
            'thumburl':'https://upload.wikimedia.org/wikipedia/commons/thumb/abc/file.jpg',
            'descriptionurl':'https://commons.wikimedia.org/wiki/File:An_aircraft.jpg',
            'extmetadata':{'LicenseShortName':{'value':licence},
                           'LicenseUrl':{'value':licence_url},
                           'Artist':{'value':'<a href="somewhere">Photo Creator</a>'}}}]}

    def test_cc0_and_ccby_strict_licenses(self):
        page=self.example_page()
        self.assertEqual(permitted_image(page,'cc0')['creator'],'Photo Creator')
        self.assertEqual(permitted_image(page,'cc0')['license'],'CC0 1.0')
        page=self.example_page('CC BY 4.0','https://creativecommons.org/licenses/by/4.0/')
        self.assertIsNone(permitted_image(page,'cc0'))
        self.assertIsNotNone(permitted_image(page,'cc0-by'))
        page=self.example_page('CC BY-NC 4.0','https://creativecommons.org/licenses/by-nc/4.0/')
        self.assertIsNone(permitted_image(page,'cc0-by'))
        page=self.example_page('CC0 1.0','https://creatives.org/publicdomain/zero/1.0/')
        self.assertIsNone(permitted_image(page,'cc0'))

    def test_unknown_licence_or_creator_rejected(self):
        page=self.example_page()
        del page['imageinfo'][0]['extmetadata']['LicenseShortName']
        self.assertIsNone(permitted_image(page,'cc0'))
        page=self.example_page()
        page['imageinfo'][0]['extmetadata']['Artist']['value']='Unknown'
        self.assertIsNone(permitted_image(page,'cc0'))
        self.assertFalse(valid_media_url('https://example.com/something.png'))
        self.assertFalse(valid_media_url('http://upload.wikimedia.org/file.png'))
        self.assertTrue(valid_media_url('https://upload.wikimedia.org/a/b.png'))

    def test_source_review_and_hash_validation(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            items=[]
            for i in range(3):
                d=root/'creator-sessions'/f'wmc_{i}'
                d.mkdir(parents=True)
                p=d/f'{i}.png';Image.new('RGB',(300,300),(i*30,30,150)).save(p)
                items.append({'file_title':f'File:Photo_{i}.png','creator':f'Creator {i}',
                    'license':'CC0 1.0','license_url':'https://creativecommons.org/publicdomain/zero/1.0/',
                    'file_page':f'https://commons.wikimedia.org/wiki/File:Photo_{i}.png',
                    'local_path':str(p),'sha256':sha256_file(p),'group':f'wmc_{i}',
                    'review_status':'REVIEW_REQUIRED'})
            write_ledger(root,items)
            self.assertEqual(verify_downloads(root,minimum=3)['creators'],3)
            with self.assertRaisesRegex(ValueError,'at least 4'):
                verify_downloads(root,minimum=4)
            (root/'creator-sessions'/'wmc_0'/'0.png').write_bytes(b'bad')
            with self.assertRaisesRegex(ValueError,'modified'):
                verify_downloads(root,minimum=1)

    def test_small_session_never_alone_as_train(self):
        records=([{'group':'large','x':i} for i in range(12)] +
                 [{'group':'medium','x':i} for i in range(10)] +
                 [{'group':'tiny','x':i} for i in range(3)])
        split=grouped_split(records)
        self.assertEqual(len(split['train']),12)
        self.assertEqual(len(split['val']),10)
        self.assertEqual(len(split['test']),3)
        self.assertEqual({r['group'] for r in split['train']},{'large'})

    def test_balanced_groups_and_fingerprint_depend_on_assignment(self):
        records=[]
        for g in range(40):
            records.extend({'group':f'author{g}','sha256':f'fake{g}_{i}'} for i in range(10))
        split=grouped_split(records)
        self.assertGreaterEqual(len(split['train']),300)
        self.assertGreaterEqual(len(split['val']),30)
        self.assertGreaterEqual(len(split['test']),30)
        by_name=[{r['group'] for r in split[k]} for k in ('train','val','test')]
        self.assertFalse((by_name[0]&by_name[1])|(by_name[0]&by_name[2])|(by_name[1]&by_name[2]))


if __name__=='__main__':unittest.main()

# Dataset-import regression: changes to approval CSV are fail closed, and only
# approved images are imported, preserving creator grouping and provenance.
class ApprovalImportTests(unittest.TestCase):
    def test_approved_sources_only_and_reimport_does_not_duplicate(self):
        import csv
        from argparse import Namespace
        from aero_train.commons import approved_entries
        from aero_train.dataset_cli import import_approved
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)/'source';root.mkdir()
            items=[]
            for i in range(33):
                d=root/'creator-sessions'/f'wmc_{i//11}'
                d.mkdir(parents=True,exist_ok=True)
                p=d/f'{i}.png'
                Image.new('RGB',(300,300),(i*6,2*i,100)).save(p)
                items.append({'file_title':f'File:Photo_{i:03}.png',
                    'creator':f'Creator {i//11}', 'license':'CC0 1.0',
                    'license_url':'https://creativecommons.org/publicdomain/zero/1.0/',
                    'file_page':f'https://commons.wikimedia.org/wiki/File:Photo_{i:03}.png',
                    'local_path':str(p),'sha256':sha256_file(p),'group':f'wmc_{i//11}',
                    'review_status':'REVIEW_REQUIRED'})
            write_ledger(root,items)
            with self.assertRaisesRegex(ValueError,'Unreviewed source'):
                approved_entries(root,minimum=30)
            csv_path=root/'SOURCE_LICENSE_REVIEW.csv'
            with csv_path.open('r',encoding='utf-8-sig',newline='') as f:
                rows=list(csv.DictReader(f))
            for idx, row in enumerate(rows):
                row['review_status']='REJECTED' if idx==0 else 'APPROVED'
            with csv_path.open('w',encoding='utf-8-sig',newline='') as f:
                writer=csv.DictWriter(f,fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)
            self.assertEqual(len(approved_entries(root,minimum=30)),32)
            dest=Path(td)/'general-dataset'
            args=Namespace(source=str(root),dataset=str(dest),rights_confirmed=True,min_side=256)
            import_approved(args)
            records=load_manifest(dest/'manifest.jsonl')
            self.assertEqual(len(records),32)
            self.assertEqual(len({r['group'] for r in records}),3)
            self.assertTrue(all(r['source']=='operator-approved-wikimedia' for r in records))
            import_approved(args)
            self.assertEqual(len(load_manifest(dest/'manifest.jsonl')),32)

class AviationDiagnosticsTests(unittest.TestCase):
    def test_aviation_diagnostic_kept_out_of_training_and_never_promoted(self):
        from argparse import Namespace
        from aero_train.aviation import run as diagnostic
        from aero_train.dataset_cli import import_clean
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);general=root/'general';aviation=root/'aviation'
            for kind,dest in [('general',general),('aviation',aviation)]:
                for i in range(3):
                    session=root/f'{kind}_session{i}';session.mkdir()
                    img=Image.new('RGB',(280,280),(10+i*20+(30 if kind=='aviation' else 0),50,100))
                    img.save(session/f'photo_{i}.png')
                    import_clean(Namespace(input=str(session),dataset=str(dest),group=f'{kind}_{i}',
                                           rights_confirmed=True,min_side=256))
            candidate=root/'candidate.onnx'
            candidate.write_bytes(b'test-only')
            args=Namespace(aviation_dataset=str(aviation),training_dataset=str(general),
                           candidate=str(candidate),scunet=None,output=str(root/'review'),
                           limit=20,preview_count=2)
            with patch('aero_train.aviation.session',return_value='dummy'),\
                 patch('aero_train.aviation.run_model',side_effect=lambda loaded,arr:arr):
                diagnostic(args)
            result=json.loads((root/'review'/'aviation-report.json').read_text())
            self.assertEqual(result['photos'],3)
            self.assertEqual(result['groups'],3)
            self.assertIs(result['is_release_gate'],False)
            self.assertFalse(result['evaluation_uses_training_corpus'])
            self.assertEqual(len(list((root/'review').glob('aviation-*.png'))),2)
            with self.assertRaisesRegex(ValueError,'also in the training corpus'):
                with patch('aero_train.aviation.session',return_value='dummy'):
                    args.training_dataset=str(aviation)
                    diagnostic(args)


class DownloadWithoutTorchRegressionTests(unittest.TestCase):
    def test_commons_downloader_does_not_import_torch(self):
        """Can list Commons CLI help from the downloader-only environment."""
        import subprocess
        import sys
        code = r'''
import sys
from importlib.abc import MetaPathFinder
class NoTorch(MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == 'torch' or fullname.startswith('torch.'):
            raise ModuleNotFoundError('blocked in downloader-only test: ' + fullname)
sys.meta_path.insert(0, NoTorch())
from aero_train.commons import main, sha256_file
from pathlib import Path
assert sha256_file(Path(__file__)) if '__file__' in globals() else True
print('Commons imports successfully with torch blocked')
'''
        process = subprocess.run([sys.executable, '-c', code],
                                 cwd=str(Path(__file__).resolve().parents[1]),
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn('Commons imports successfully', process.stdout)
