"""Optional, locally run Wikimedia Commons clean-photo discovery.

No photographs are bundled with AeroStudios, and fetching is never automatic.
Only explicitly allowlisted licence metadata is accepted. An operator must
review the provenance ledger and confirm reuse permissions separately before
passing downloaded images to the training dataset importer.
"""
from __future__ import annotations

import argparse
import csv
from collections import Counter
import hashlib
import html
import io
import json
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

from PIL import Image, ImageOps

from .hashutil import sha256_file

API = 'https://commons.wikimedia.org/w/api.php'
DEFAULT_QUERIES = (
    'landscape nature photograph',
    'forest landscape photograph',
    'mountain landscape photograph',
    'architecture building photograph',
    'city street photograph',
    'aircraft aviation photograph',
    'wildlife bird photograph',
    'plant flower macro photograph',
    'sea coast photograph',
    'interior architecture photograph',
    'vehicle automobile photograph',
    'night city photography',
)
ALLOWLIST = {
    'cc0': {'CC0', 'CC0 1.0'},
    'cc0-by': {'CC0', 'CC0 1.0', 'CC BY 4.0', 'CC BY 3.0', 'CC BY 2.0'},
}
# List CC0 files directly instead of relying only on full-text search rankings.
# Start at different filename prefixes to improve creator/subject diversity.
# The category is a discovery aid, NOT proof that the individual file is CC0:
# permitted_image() still checks the file-specific imageinfo metadata.
CC0_CATEGORY = 'Category:CC-Zero'
CC0_SORT_PREFIXES = ('A', 'C', 'E', 'G', 'I', 'K', 'M', 'O', 'Q', 'S', 'U', 'W', 'Y',
                     '0', '1', '2', '3', '4', '5', '6', '7', '8', '9')
MAX_IMAGE_BYTES = 16 * 1024 * 1024
CSV_FIELDS = ('file_title','creator','license','license_url','file_page','query',
              'local_path','sha256','group','review_status')


def plain(value: str) -> str:
    return re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]*>', ' ', value or ''))).strip()


def metadata_value(ext: dict, key: str) -> str:
    v = ext.get(key, '')
    return plain(v.get('value', '') if isinstance(v, dict) else str(v))


def normalize_license(value: str) -> str:
    return ' '.join(value.upper().strip().replace('_', ' ').split())


def permitted_image(page: dict, mode: str) -> dict | None:
    if not page.get('title', '').startswith('File:'):
        return None
    info = (page.get('imageinfo') or [None])[0]
    if not isinstance(info, dict):
        return None
    if min(info.get('width', 0), info.get('height', 0)) < 512:
        return None
    ext = info.get('extmetadata') or {}
    license_short = normalize_license(metadata_value(ext, 'LicenseShortName'))
    if license_short not in ALLOWLIST[mode]:
        return None
    license_url = metadata_value(ext, 'LicenseUrl')
    license_endpoint=urlparse(license_url)
    if license_endpoint.scheme not in ('https', 'http') or license_endpoint.hostname not in ('creativecommons.org','www.creativecommons.org'):
        return None
    if license_short in ('CC0', 'CC0 1.0'):
        if not license_endpoint.path.startswith('/publicdomain/zero/1.0'):
            return None
    else:
        version = license_short.split()[-1]
        if not license_endpoint.path.startswith(f'/licenses/by/{version}'):
            return None
    creator = metadata_value(ext, 'Artist')
    if len(creator) < 2 or creator.casefold() in ('unknown', 'anonymous', 'n/a', 'own work', 'wikimedia commons'):
        return None
    source_url = info.get('thumburl') or info.get('url')
    if not valid_media_url(source_url):
        return None
    description_url = info.get('descriptionurl')
    if not (isinstance(description_url, str) and description_url.startswith('https://commons.wikimedia.org/wiki/File:')):
        return None
    group = 'wmc_' + hashlib.sha256(creator.casefold().encode('utf-8')).hexdigest()[:16]
    return {'title':page['title'], 'license':license_short, 'license_url':license_url,
            'creator':creator[:300], 'group':group, 'file_page':description_url,
            'source_url':source_url}


def valid_media_url(url) -> bool:
    if not isinstance(url, str):
        return False
    u=urlparse(url)
    return u.scheme=='https' and u.hostname == 'upload.wikimedia.org' and not (u.username or u.password)


def _safe_urlopen(req, *, timeout: int=35):
    response = urlopen(req, timeout=timeout)
    final = response.geturl()
    original = req.full_url
    # Never fetch redirected image bytes from a third-party image host.
    if original.startswith('https://upload.wikimedia.org/') and not valid_media_url(final):
        response.close()
        raise ValueError('Unexpected media redirect outside Wikimedia host')
    return response


def open_retry(request: Request, tries=3):
    for index in range(tries):
        try:
            return _safe_urlopen(request)
        except HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or index == tries-1:
                raise
            seconds = int(e.headers.get('Retry-After', '0') or 0)
            time.sleep(min(60, max(seconds, 2 * (2 ** index))))
        except (URLError, TimeoutError):
            if index == tries-1:
                raise
            time.sleep(2 * (2 ** index))


def query_api(params: dict, user_agent: str):
    params={'format':'json','formatversion':2,'maxlag':5,**params}
    url = API + '?' + urlencode(params)
    request=Request(url,headers={'User-Agent':user_agent,'Accept':'application/json'})
    with open_retry(request) as response:
        raw=response.read(8 * 1024 * 1024 + 1)
    if len(raw)>8 * 1024 * 1024:
        raise ValueError('Unexpectedly large API response')
    parsed=json.loads(raw)
    if 'error' in parsed:
        raise ValueError('Wikimedia API error: '+str(parsed['error']))
    return parsed


def download_image(url: str, user_agent: str, dest: Path, min_side: int=512):
    if not valid_media_url(url):
        raise ValueError('Invalid Wikimedia media URL')
    request=Request(url,headers={'User-Agent':user_agent})
    with open_retry(request) as response:
        b=response.read(MAX_IMAGE_BYTES+1)
    if len(b)>MAX_IMAGE_BYTES:
        raise ValueError('Media file exceeds local download limit')
    with Image.open(io.BytesIO(b)) as image:
        if image.format not in ('JPEG', 'PNG'):
            raise ValueError('Only JPEG and PNG source photos are supported')
        clean=ImageOps.exif_transpose(image).convert('RGB')
        if min(clean.size)<min_side:
            raise ValueError('Image is too small after download')
        dest.parent.mkdir(parents=True,exist_ok=True)
        temp=dest.with_suffix('.tmp')
        # Re-encoding removes image metadata and original names, avoids another
        # lossy JPEG pass; pixel quality is limited by the source itself.
        try:
            clean.save(temp, format='PNG', compress_level=3)
            temp.replace(dest)
        finally:
            temp.unlink(missing_ok=True)
    return sha256_file(dest)


def write_ledger(root: Path, entries: list[dict]):
    # Retain operator decisions on incremental downloads (never silently approve).
    csv_path=root/'SOURCE_LICENSE_REVIEW.csv'
    decisions={}
    if csv_path.is_file():
        with csv_path.open('r',encoding='utf-8-sig',newline='') as source:
            for prior in csv.DictReader(source):
                if prior.get('review_status','').strip().upper() in ('APPROVED','REJECTED'):
                    decisions[prior.get('sha256','')]=prior['review_status'].strip().upper()
    entries=sorted(entries,key=lambda e: e['file_title'])
    manifest=root/'source-ledger.jsonl'
    tmp=manifest.with_suffix('.tmp')
    with tmp.open('w',encoding='utf-8') as f:
        for item in entries: f.write(json.dumps(item,ensure_ascii=False,sort_keys=True)+'\n')
    tmp.replace(manifest)
    with (root/'SOURCE_LICENSE_REVIEW.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=CSV_FIELDS)
        writer.writeheader()
        for e in entries:
            row={key:e.get(key,'') for key in CSV_FIELDS}
            row['review_status']=decisions.get(e['sha256'],'REVIEW_REQUIRED')
            # CSV/formula injection mitigation when opened in spreadsheet apps.
            row={k:("'"+v if isinstance(v,str) and v.lstrip().startswith(('=', '+', '-', '@')) else v)
                 for k,v in row.items()}
            writer.writerow(row)


def read_ledger(root: Path) -> list[dict]:
    ledger=root/'source-ledger.jsonl'
    if not ledger.is_file():
        raise ValueError('No source ledger; run the download step first')
    entries=[json.loads(line) for line in ledger.read_text(encoding='utf-8').splitlines() if line.strip()]
    if not entries:
        raise ValueError('The ledger has no eligible photographs')
    return entries


def verify_downloads(root: Path, *, minimum: int=30, minimum_creators: int=3):
    """Verify source files and provenance without weakening import requirements.

    A download in progress can legitimately have only one or two creators.
    Call with minimum=1, minimum_creators=1 when resuming an unfinished
    collection; the public verify/import commands retain the >=3 creator gate.
    """
    items=read_ledger(root)
    groups=set()
    for e in items:
        p=Path(e['local_path']).resolve()
        if not p.is_file() or p.is_symlink() or not p.is_relative_to((root/'creator-sessions').resolve()):
            raise ValueError('Missing/outside dataset image: '+str(p))
        if sha256_file(p)!=e['sha256']:
            raise ValueError('Downloaded image was modified: '+str(p))
        if normalize_license(e['license']) not in ALLOWLIST['cc0-by']:
            raise ValueError('Unapproved licence in ledger')
        if not e.get('file_page') or not e.get('creator'):
            raise ValueError('Incomplete attribution/provenance ledger')
        groups.add(e['group'])
    if len(items)<minimum:
        raise ValueError(f'Only {len(items)} photos; need at least {minimum} before training. Download more.')
    if len(groups)<minimum_creators:
        raise ValueError(f'Only {len(groups)} independent creators; need at least {minimum_creators}.')
    return {'images':len(items),'creators':len(groups),'ledger':str(root/'SOURCE_LICENSE_REVIEW.csv')}


def approved_entries(root: Path, *, minimum: int=30) -> list[dict]:
    """Fail-closed operator decisions from a provenance-preserving review CSV."""
    originals=read_ledger(root)
    ledger={row['sha256']:row for row in originals}
    if len(ledger)!=len(originals):
        raise ValueError('Duplicate source SHA-256 in provenance ledger')
    review=root/'SOURCE_LICENSE_REVIEW.csv'
    if not review.is_file():
        raise ValueError('Review CSV missing')
    seen=set();approved=[]
    with review.open('r',encoding='utf-8-sig',newline='') as f:
        for row in csv.DictReader(f):
            sha=row.get('sha256','').strip()
            if sha in seen or sha not in ledger:
                raise ValueError('Unknown or duplicate source hash in review CSV')
            seen.add(sha)
            original=ledger[sha]
            # Only review_status is editable; tampered provenance is rejected.
            for key in ('file_title','creator','license','license_url','file_page',
                        'local_path','group'):
                if row.get(key,'')!=original.get(key,''):
                    raise ValueError('Review CSV changed source provenance: '+str(original['file_title']))
            status=row.get('review_status','').strip().upper()
            if status=='APPROVED':approved.append(original)
            elif status=='REJECTED':continue
            elif status=='REVIEW_REQUIRED':
                raise ValueError('Unreviewed source: '+str(original['file_title']))
            else:
                raise ValueError('Set review_status to APPROVED or REJECTED for each source')
    if seen!=set(ledger):
        raise ValueError('Review CSV missing ledger entries')
    if len(approved)<minimum:
        raise ValueError(f'Only {len(approved)} individually approved photos; need at least {minimum}')
    if len({e['group'] for e in approved})<3:
        raise ValueError('Approved collection needs at least three distinct creator groups')
    for entry in approved:
        p=Path(entry['local_path']).resolve()
        if p.is_symlink() or not p.is_file() or not p.is_relative_to((root/'creator-sessions').resolve()):
            raise ValueError('Missing/invalid approved image: '+str(p))
        if sha256_file(p)!=entry['sha256']:
            raise ValueError('Approved source image changed: '+str(p))
        if normalize_license(entry['license']) not in ALLOWLIST['cc0-by']:
            raise ValueError('Unsupported license in review')
    return approved


def category_request(prefix: str, limit: int, continuation: dict | None = None) -> dict:
    """MediaWiki generator query: categorymembers plus per-file imageinfo in one call.

    gcmstartsortkeyprefix is a starting point (not a filter); each independent
    prefix is capped by the scanning limit to avoid scanning one creator forever.
    """
    query = {'action':'query','generator':'categorymembers',
             'gcmtitle':CC0_CATEGORY,'gcmtype':'file','gcmnamespace':6,
             'gcmlimit':min(50,limit),'gcmstartsortkeyprefix':prefix,
             'prop':'imageinfo','iiprop':'url|size|extmetadata','iiurlwidth':1600}
    query.update(continuation or {})
    return query


def download(args):
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',args.contact):
        raise ValueError('Provide a real contact email for Wikimedia API identification (not stored in data files)')
    if args.target<30 or args.target>10000:
        raise ValueError('Target must be between 30 and 10000 images')
    if not 1 <= args.max_per_creator <= 1000:
        raise ValueError('Max per creator must be between 1 and 1000')
    root=Path(args.output).resolve()
    root.mkdir(parents=True,exist_ok=True)
    user_agent=f'AeroStudiosPrivateImageTraining/0.2 (mailto:{args.contact}) Python-urllib'
    ledger_path=root/'source-ledger.jsonl'
    entries=read_ledger(root) if ledger_path.is_file() and ledger_path.stat().st_size else []
    old_titles={entry['file_title'] for entry in entries}
    old_hashes={entry['sha256'] for entry in entries}
    by_creator=Counter(e['group'] for e in entries)
    if entries:
        verify_downloads(root,minimum=1,minimum_creators=1)
    queries=list(args.query or DEFAULT_QUERIES)
    if not queries and args.discovery!='cc0-category':
        raise ValueError('At least one search query is required')
    stats=Counter()

    def consider(page: dict, source: str, *, jpeg_only=False):
        title=page.get('title','')
        if not isinstance(title,str) or not title.startswith('File:') or title in old_titles:
            stats['previously_seen']+=1
            return
        # The direct CC-Zero category contains diagrams, logos, etc. JPEG files
        # are more likely to be usable natural photos, but still need a human review.
        if jpeg_only and not title.lower().endswith(('.jpg','.jpeg')):
            stats['not_jpeg']+=1
            return
        info=permitted_image(page,args.license_mode)
        if info is None:
            stats['metadata_filtered']+=1
            return
        if by_creator[info['group']]>=args.max_per_creator:
            stats['creator_limit']+=1
            return
        item_id=hashlib.sha256(info['title'].encode()).hexdigest()[:20]
        dest=root/'creator-sessions'/info['group']/(item_id+'.png')
        try:
            sha=download_image(info['source_url'],user_agent,dest)
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as ex:
            print('Skipped media:',info['title'][:70],str(ex)[:120],flush=True)
            stats['media_failed']+=1
            return
        if sha in old_hashes:
            dest.unlink(missing_ok=True)
            stats['duplicate_pixels']+=1
            return
        entry={'file_title':info['title'],'creator':info['creator'],
               'license':info['license'],'license_url':info['license_url'],
               'file_page':info['file_page'],'source_url':info['source_url'],
               'query':source,'sha256':sha,'group':info['group'],
               'local_path':str(dest.resolve()),'review_status':'REVIEW_REQUIRED'}
        entries.append(entry)
        old_titles.add(info['title']);old_hashes.add(sha)
        by_creator[info['group']]+=1
        stats['accepted']+=1
        if len(entries)%10==0:
            write_ledger(root,entries)
            print(f'Downloaded {len(entries)}/{args.target} images, {len(by_creator)} creators',flush=True)
        time.sleep(max(args.delay,0.25))

    # Directly scan Wikimedia's CC-Zero category, with an independent metadata
    # check for each file. This addresses the near-zero yield from generic search.
    if args.discovery in ('auto','cc0-category'):
        for prefix in CC0_SORT_PREFIXES:
            if len(entries)>=args.target:
                break
            continuation={}
            scanned=0
            print(f'Scanning CC-Zero category from prefix {prefix}:',flush=True)
            while len(entries)<args.target and scanned<args.max_results_per_query:
                params=category_request(prefix,args.max_results_per_query-scanned,continuation)
                result=query_api(params,user_agent)
                pages=(result.get('query') or {}).get('pages') or []
                scanned+=len(pages)
                stats['category_scanned']+=len(pages)
                for page in pages:
                    if len(entries)>=args.target:
                        break
                    consider(page,'commons-category:CC-Zero',jpeg_only=True)
                continuation=result.get('continue') or {}
                if not continuation or not pages:
                    break
                time.sleep(max(args.delay,0.25))
            write_ledger(root,entries)
            print(f'Category progress: {len(entries)}/{args.target} accepted, '
                  f'{stats["category_scanned"]} category files inspected',flush=True)

    # Search is also available for extra coverage, and can be used alone via
    # --discovery search. Both discovery paths use the same rights verification.
    if args.discovery in ('auto','search'):
        for search_term in queries:
            if len(entries)>=args.target:
                break
            print('Searching Wikimedia Commons:',search_term,flush=True)
            continuation={}
            scanned=0
            while len(entries)<args.target and scanned<args.max_results_per_query:
                limit=min(25,args.max_results_per_query-scanned)
                query={'action':'query','list':'search','srsearch':search_term,
                       'srnamespace':6,'srlimit':limit}
                query.update(continuation)
                search=query_api(query,user_agent)
                found=(search.get('query') or {}).get('search') or []
                if not found:
                    break
                scanned+=len(found)
                stats['search_scanned']+=len(found)
                titles=[r['title'] for r in found if r.get('title','').startswith('File:') and r['title'] not in old_titles]
                if titles:
                    details=query_api({'action':'query','prop':'imageinfo',
                        'iiprop':'url|size|extmetadata','iiurlwidth':1600,
                        'titles':'|'.join(titles)},user_agent)
                    for page in (details.get('query') or {}).get('pages',[]):
                        if len(entries)>=args.target:break
                        consider(page,search_term)
                continuation=search.get('continue') or {}
                if not continuation:
                    break
                time.sleep(max(args.delay,0.25))
            write_ledger(root,entries)

    write_ledger(root,entries)
    result={'downloaded':len(entries),'creators':len(by_creator),
            'target':args.target,'discovery':args.discovery,
            'status':'REQUIRES HUMAN LICENCE/SOURCE REVIEW BEFORE TRAINING',
            'ledger':str(root/'SOURCE_LICENSE_REVIEW.csv'),
            'diagnostics':dict(stats)}
    print(json.dumps(result,indent=2))
    if len(entries)<args.target:
        print('Target not reached. Check diagnostics: large metadata_filtered '
              'means most candidates do not meet strict CC0/creator rules. '
              'Run again to resume; do not approve unverified rights.')


def main():
    p=argparse.ArgumentParser(description='Private opt-in Wikimedia Commons image collection; operator review required')
    sub=p.add_subparsers(dest='command',required=True)
    d=sub.add_parser('download',help='Fetch provenance-checked photos, never train automatically')
    d.add_argument('--output',required=True)
    d.add_argument('--contact',required=True,help='Real Wikimedia User-Agent contact email')
    d.add_argument('--target',type=int,default=500)
    d.add_argument('--license-mode',choices=ALLOWLIST,default='cc0')
    d.add_argument('--discovery',choices=('auto','search','cc0-category'),default='auto')
    d.add_argument('--max-per-creator',type=int,default=30)
    d.add_argument('--query',action='append',help='Custom Wikimedia search query; repeat for multiple')
    d.add_argument('--delay',type=float,default=.65)
    d.add_argument('--max-results-per-query',type=int,default=300)
    d.set_defaults(func=download)
    v=sub.add_parser('verify',help='Verify download integrity and group counts')
    v.add_argument('--output',required=True)
    v.add_argument('--minimum',type=int,default=30)
    v.set_defaults(func=lambda a:print(json.dumps(verify_downloads(Path(a.output).resolve(),minimum=a.minimum),indent=2)))
    a=sub.add_parser('approved',help='Check each row of manually approved/rejected source rights CSV')
    a.add_argument('--output',required=True)
    a.add_argument('--minimum',type=int,default=30)
    a.set_defaults(func=lambda args:print(json.dumps(
        {'approved':len(approved_entries(Path(args.output).resolve(),minimum=args.minimum)),
         'status':'OPERATOR RIGHTS REVIEW RECORDED; legal clearance remains operator responsibility'},indent=2)))
    args=p.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, HTTPError, URLError) as ex:
        p.error(str(ex))

if __name__=='__main__':main()
