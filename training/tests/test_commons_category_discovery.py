"""Offline regression tests for CC0 direct category discovery and resume."""
from __future__ import annotations

import contextlib
import csv
import io
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from aero_train.commons import (CC0_SORT_PREFIXES, category_request, download,
                                read_ledger, verify_downloads, write_ledger)
from aero_train.hashutil import sha256_file


class CategoryDiscoveryTests(unittest.TestCase):
    def test_category_generator_parameters(self):
        query=category_request('K',50,{'gcmcontinue':'abc','continue':'gcmcontinue||'})
        self.assertEqual(query['generator'],'categorymembers')
        self.assertEqual(query['gcmtitle'],'Category:CC-Zero')
        self.assertEqual(query['gcmstartsortkeyprefix'],'K')
        self.assertEqual(query['gcmtype'],'file')
        self.assertEqual(query['gcmnamespace'],6)
        self.assertEqual(query['prop'],'imageinfo')
        self.assertEqual(query['gcmcontinue'],'abc')

    def test_resume_from_two_creators_before_import_is_allowed(self):
        """Regression: integrity checks must not block a partial dataset."""
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            entries=[]
            for i in range(2):
                source=root/'creator-sessions'/f'old_creator_{i}'/f'old_{i}.png'
                source.parent.mkdir(parents=True)
                Image.new('RGB',(514,514),(20 + i * 20,30,40)).save(source)
                entries.append({'file_title':f'File:Existing_{i}.jpg',
                    'creator':f'Existing Creator {i}', 'license':'CC0 1.0',
                    'license_url':'https://creativecommons.org/publicdomain/zero/1.0/',
                    'file_page':f'https://commons.wikimedia.org/wiki/File:Existing_{i}.jpg',
                    'local_path':str(source),'sha256':sha256_file(source),
                    'group':f'old_creator_{i}','review_status':'REVIEW_REQUIRED'})
            write_ledger(root,entries)
            # Final import/verify still refuses this incomplete collection.
            with self.assertRaisesRegex(ValueError,'independent creators'):
                verify_downloads(root,minimum=1)

            def fake_query(params, _ua):
                prefix=params['gcmstartsortkeyprefix']
                pages=[]
                for i in range(4):
                    title=f'File:New_{prefix}_{i}.jpg'
                    pages.append({'title':title,'imageinfo':[{
                        'width':2048,'height':1365,
                        'thumburl':f'https://upload.wikimedia.org/wikipedia/commons/{prefix}_{i}.jpg',
                        'descriptionurl':f'https://commons.wikimedia.org/wiki/{title}',
                        'extmetadata':{
                            'LicenseShortName':{'value':'CC0 1.0'},
                            'LicenseUrl':{'value':'https://creativecommons.org/publicdomain/zero/1.0/'},
                            'Artist':{'value':f'New Creator {prefix}'}}}]})
                return {'query':{'pages':pages}}

            def fake_download(_url, _ua, dest):
                dest.parent.mkdir(parents=True,exist_ok=True)
                n=int(dest.stem[:8],16)
                Image.new('RGB',(514,514),((n>>16)&255,(n>>8)&255,n&255)).save(dest)
                return sha256_file(dest)

            args=Namespace(output=str(root),contact='developer@example.com',
                target=30,license_mode='cc0',query=None,discovery='cc0-category',
                max_per_creator=3,max_results_per_query=30,delay=0)
            with patch('aero_train.commons.query_api',side_effect=fake_query), \
                 patch('aero_train.commons.download_image',side_effect=fake_download), \
                 patch('aero_train.commons.time.sleep'), \
                 contextlib.redirect_stdout(io.StringIO()):
                download(args)
            result=read_ledger(root)
            self.assertEqual(len(result),30)
            self.assertGreaterEqual(len({item['group'] for item in result}),3)
            self.assertEqual(verify_downloads(root)['images'],30)

    def test_category_fetch_retains_ledger_and_limits_creators(self):
        def fake_query(params, _user_agent):
            if params.get('generator')!='categorymembers':
                raise AssertionError('Unexpected search request')
            p=params['gcmstartsortkeyprefix']
            result=[]
            for i in range(5):
                title=f'File:CCzero_{p}_{i}.jpg'
                result.append({'title':title,'imageinfo':[{'width':2048,'height':1365,
                    'thumburl':f'https://upload.wikimedia.org/wikipedia/commons/{p}_{i}.jpg',
                    'descriptionurl':f'https://commons.wikimedia.org/wiki/{title}',
                    'extmetadata':{
                        'LicenseShortName':{'value':'CC0 1.0'},
                        'LicenseUrl':{'value':'https://creativecommons.org/publicdomain/zero/1.0/'},
                        'Artist':{'value':f'Creator {p}'}}}]})
            # A non-CC0 photograph and a diagram must be excluded even in the category.
            result.append({'title':f'File:Not_CC0_{p}.jpg','imageinfo':[{'width':2048,'height':1365,
                'thumburl':f'https://upload.wikimedia.org/wikipedia/commons/not_{p}.jpg',
                'descriptionurl':f'https://commons.wikimedia.org/wiki/File:Not_CC0_{p}.jpg',
                'extmetadata':{'LicenseShortName':{'value':'CC BY-SA 4.0'},
                    'LicenseUrl':{'value':'https://creativecommons.org/licenses/by-sa/4.0/'},
                    'Artist':{'value':f'Creator {p}'}}}]})
            return {'query':{'pages':result}}

        def fake_download(url, _agent, dest):
            dest.parent.mkdir(parents=True,exist_ok=True)
            # Unique image pixels for each downloaded file.
            n=int(dest.stem[:8],16)
            Image.new('RGB',(514,514),((n >> 16) & 255,(n >> 8) & 255,n & 255)).save(dest)
            return sha256_file(dest)

        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            args=Namespace(output=str(root),contact='developer@example.com',
                target=30,license_mode='cc0',query=None,discovery='cc0-category',
                max_per_creator=3,max_results_per_query=30,delay=0)
            with patch('aero_train.commons.query_api',side_effect=fake_query), \
                 patch('aero_train.commons.download_image',side_effect=fake_download), \
                 patch('aero_train.commons.time.sleep'),\
                 contextlib.redirect_stdout(io.StringIO()):
                download(args)
            entries=read_ledger(root)
            self.assertEqual(len(entries),30)
            self.assertEqual(len({x['group'] for x in entries}),10)
            self.assertTrue(all(x['license']=='CC0 1.0' for x in entries))
            self.assertTrue(all(x['query']=='commons-category:CC-Zero' for x in entries))
            self.assertEqual(verify_downloads(root)['images'],30)
            # Decisions from already reviewed images remain after incremental downloads.
            review=root/'SOURCE_LICENSE_REVIEW.csv'
            with review.open(encoding='utf-8-sig',newline='') as f:
                rows=list(csv.DictReader(f))
            chosen=rows[0]['sha256']
            rows[0]['review_status']='APPROVED'
            with review.open('w',encoding='utf-8-sig',newline='') as f:
                writer=csv.DictWriter(f,fieldnames=rows[0].keys()); writer.writeheader();writer.writerows(rows)
            args.target=36
            with patch('aero_train.commons.query_api',side_effect=fake_query), \
                 patch('aero_train.commons.download_image',side_effect=fake_download), \
                 patch('aero_train.commons.time.sleep'),\
                 contextlib.redirect_stdout(io.StringIO()):
                download(args)
            self.assertEqual(len(read_ledger(root)),36)
            with review.open(encoding='utf-8-sig',newline='') as f:
                statuses={x['sha256']:x['review_status'] for x in csv.DictReader(f)}
            self.assertEqual(statuses[chosen],'APPROVED')
            self.assertEqual(len({x['group'] for x in read_ledger(root)}),12)


if __name__=='__main__':
    unittest.main()
