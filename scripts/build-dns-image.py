import gzip
import hashlib
import io
import json
import pathlib
import tarfile

root = pathlib.Path(__file__).resolve().parents[1]
folder = root / 'RuntimeSupport/DNS'

def archive(files):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as tar:
        for name, content, mode in files:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = mode
            info.mtime = 0
            tar.addfile(info, io.BytesIO(content))
    return data.getvalue()

def encoded(value):
    return json.dumps(value, separators=(',', ':'), sort_keys=True).encode()

def descriptor(data, kind):
    return {'mediaType': kind, 'digest': 'sha256:' + hashlib.sha256(data).hexdigest(), 'size': len(data)}

layer = archive([('dns-forwarder', (folder / 'dns-forwarder').read_bytes(), 0o755)])
packed = gzip.compress(layer, mtime=0)
config = encoded({'architecture':'arm64', 'os':'linux', 'config':{'Entrypoint':['/dns-forwarder']}, 'rootfs':{'type':'layers', 'diff_ids':['sha256:' + hashlib.sha256(layer).hexdigest()]}})
manifest = encoded({'schemaVersion':2, 'mediaType':'application/vnd.oci.image.manifest.v1+json', 'config':descriptor(config,'application/vnd.oci.image.config.v1+json'), 'layers':[descriptor(packed,'application/vnd.oci.image.layer.v1.tar+gzip')]})
entry = descriptor(manifest,'application/vnd.oci.image.manifest.v1+json')
entry['annotations'] = {'org.opencontainers.image.ref.name':'socktainer-dns:acgui8'}
entry['platform'] = {'architecture':'arm64','os':'linux'}
index = encoded({'schemaVersion':2,'manifests':[entry]})
files = [('oci-layout',b'{"imageLayoutVersion":"1.0.0"}',0o644),('index.json',index,0o644)]
for blob in [config,packed,manifest]:
    files.append(('blobs/sha256/' + hashlib.sha256(blob).hexdigest(),blob,0o644))
(folder / 'image.tar.gz').write_bytes(gzip.compress(archive(files),mtime=0))
print('Built embedded DNS image')
