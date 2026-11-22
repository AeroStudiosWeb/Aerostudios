"""Create or revoke per-user feedback API tokens. No third-party packages.
Run on operator's machine, never commit the JSON file or reveal tokens in logs.
"""
import argparse
import hashlib
import json
import os
import re
import secrets
from pathlib import Path


def read_file(path):
    if path.exists():
        data=json.loads(path.read_text(encoding='utf-8'))
        if data.get('schema')!=1 or not isinstance(data.get('clients'),list):
            raise ValueError('Unknown token-file format')
        return data
    return {'schema':1,'clients':[]}


def save(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.tmp')
    with open(tmp,'w',encoding='utf-8') as f:
        os.chmod(tmp,0o600)
        json.dump(data,f,indent=2)
        f.write('\n')
    os.replace(tmp,path)


def create(path,identity):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,60}',identity):raise ValueError('Use anonymous alphanumeric client IDs')
    data=read_file(path)
    if any(c.get('id')==identity for c in data['clients']):raise ValueError('Client ID already exists; revoke or choose a new ID')
    token=secrets.token_urlsafe(36)
    data['clients'].append({'id':identity,'sha256':hashlib.sha256(token.encode()).hexdigest(),'enabled':True})
    save(path,data)
    return token


def revoke(path,identity):
    data=read_file(path)
    found=False
    for c in data['clients']:
        if c.get('id')==identity:c['enabled']=False;found=True
    if not found:raise ValueError('Unknown client ID')
    save(path,data)


def main():
    p=argparse.ArgumentParser(description='Issue/revoke invitation-only AeroEnhance community feedback tokens')
    p.add_argument('action',choices=['create','revoke','list'])
    p.add_argument('--file',type=Path,required=True)
    p.add_argument('--client-id',default='')
    a=p.parse_args()
    if a.action=='create':
        token=create(a.file,a.client_id)
        print('TOKEN (shown ONCE; deliver to the user privately):',token)
        print('Restart feedback server to load new client list. NEVER commit or embed tokens.')
    elif a.action=='revoke':
        revoke(a.file,a.client_id)
        print('Token revoked in file. Restart server to apply.')
    else:
        print(json.dumps([{'id':c['id'],'enabled':c['enabled']} for c in read_file(a.file)['clients']],indent=2))

if __name__=='__main__':main()
