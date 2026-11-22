"""Security and quality-gate regression tests for community learning."""
import csv
import hashlib
import json
import tempfile
import time
import uuid
from pathlib import Path

import pytest

from aero_train.community_review import sync
from aero_train.community_benchmark import compare_metrics
from aero_train.community_release import evaluate_release, filehash


def test_review_merges_new_contributions_and_preserves_votes(tmp_path):
    store=tmp_path/'feedback';store.mkdir()
    identifiers=[str(uuid.uuid4()) for _ in range(3)]
    for i,identity in enumerate(identifiers):
        folder=store/identity;folder.mkdir()
        (folder/'before.png').write_bytes(b'not an actual image; review index only')
        (folder/'metadata.json').write_text(json.dumps({'id':identity,'training_permission':True,
            'with_example':True,'consent_version':'2026-11-beta-v2-training',
            'expires_unix':int(time.time())+(100 if i!=2 else -100)}))
    target=tmp_path/'review.csv'
    assert sync(store,target)['active']==2
    with target.open(newline='') as f:rows=list(csv.DictReader(f))
    rows[0].update(group='photographer01',clean_confirmed='YES',license_checked='YES')
    with target.open('w',newline='') as f:
        wr=csv.DictWriter(f,fieldnames=rows[0].keys());wr.writeheader();wr.writerows(rows)
    new_id=str(uuid.uuid4());folder=store/new_id;folder.mkdir()
    (folder/'before.png').write_bytes(b'dummy')
    (folder/'metadata.json').write_text(json.dumps({'id':new_id,'training_permission':True,
        'with_example':True,'consent_version':'2026-11-beta-v2-training','expires_unix':int(time.time())+200}))
    state=sync(store,target)
    assert state=={'active':3,'new':1,'approved':1}
    with target.open(newline='') as f: byid={r['id']:r for r in csv.DictReader(f)}
    assert byid[rows[0]['id']]['clean_confirmed']=='YES'
    assert byid[new_id]['clean_confirmed']=='NO'
    (store/rows[0]['id']/'metadata.json').unlink()
    assert sync(store,target)['approved']==0


def test_quality_gate_blocks_regression():
    current={'psnr_db':30.0,'edge_mae':0.02,'noisy_psnr_db':24.0}
    better={'psnr_db':30.25,'edge_mae':0.019,'noisy_psnr_db':24.0}
    assert compare_metrics(better,current)['passed']
    assert not compare_metrics({**better,'edge_mae':0.021},current)['passed']
    assert not compare_metrics({**better,'psnr_db':30.08},current)['passed']


def test_staging_denies_missing_human_review_or_failed_gate(tmp_path):
    model=tmp_path/'candidate.onnx';model.write_bytes(b'tiny-test-only')
    cp='ab'*32
    benchmark={'schema':1,'gate':{'passed':True},'synthetic_only':True,
       'human_review_required':True,'benchmark_images':25,'independent_groups':3,'candidate_checkpoint_sha256':cp}
    validation={'sha256':filehash(model),'checkpoint_sha256':cp}
    heldout={'automatic_gate_passed':True,'checkpoint_sha256':cp}
    args=(benchmark,validation,heldout,model)
    with pytest.raises(ValueError,match='human-image-review'):
        evaluate_release(*args,'NO','0.2.0','https://example.com/file.onnx')
    with pytest.raises(ValueError,match='benchmark'):
        evaluate_release({**benchmark,'gate':{'passed':False}},validation,heldout,model,
                         'I REVIEWED THE IMAGES AND APPROVE THIS CANDIDATE','0.2.0','https://example.com/file.onnx')
    with pytest.raises(ValueError,match='HTTPS'):
        evaluate_release(*args,'I REVIEWED THE IMAGES AND APPROVE THIS CANDIDATE','0.2.0','http://example.com/file.onnx')
    release=evaluate_release(*args,'I REVIEWED THE IMAGES AND APPROVE THIS CANDIDATE',
                  '0.2.0','https://example.com/aero-denoise.onnx')
    assert release['sha256']==hashlib.sha256(model.read_bytes()).hexdigest()
    assert release['channel']=='beta' and release['schema']==1


def test_token_issuer_preserves_only_digests(tmp_path):
    import sys
    sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'services'/'feedback-server'))
    # source is outside the training package: import manually from exact file
    import importlib.util
    p=Path(__file__).resolve().parents[2]/'services'/'feedback-server'/'client_token_admin.py'
    spec=importlib.util.spec_from_file_location('client_token_admin',p)
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    store=tmp_path/'client-tokens.json'
    token=mod.create(store,'community001')
    data=json.loads(store.read_text())
    assert len(token)>=32 and token not in store.read_text()
    assert data['clients'][0]['sha256']==hashlib.sha256(token.encode()).hexdigest()
    mod.revoke(store,'community001')
    assert json.loads(store.read_text())['clients'][0]['enabled'] is False
