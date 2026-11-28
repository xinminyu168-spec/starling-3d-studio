#!/usr/bin/env python3
"""Build an opt-in Starling signed GLB asset pack using the existing permanent key."""
import argparse, base64, getpass, hashlib, json, os, struct, subprocess, tempfile, zipfile
from pathlib import Path

CERT = "065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba"
SOURCE = "97c80d3a7f5b8e6412687ab30574fa4efdb5cd4db0a3115356de426ae411e379"
MATERIALS = {"General", "Skin_candidate", "Hair_candidate", "Blue_fabric_candidate", "Painted_shell_candidate", "Metal_candidate", "Goggle_lens_candidate", "Eye_surface_candidate"}

def check_model(p):
    size = p.stat().st_size
    if not 20 <= size <= 150_000_000:
        raise ValueError("asset size out of range")
    with p.open("rb") as f:
        magic, ver, declared, jsize, jtype = struct.unpack("<5I", f.read(20))
        if magic != 0x46546c67 or ver != 2 or declared != size or jtype != 0x4e4f534a or not 2 <= jsize <= 4_000_000 or jsize % 4:
            raise ValueError("invalid GLB header")
        doc = json.loads(f.read(jsize))
        mats = doc["materials"]
        if len(mats) != 8 or {m["name"] for m in mats} != MATERIALS:
            raise ValueError("semantic8 material profile required")
        if len(doc["buffers"]) != 1 or any("uri" in x for x in doc["buffers"] + doc["images"]):
            raise ValueError("external buffers/images forbidden")
    return size

def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda: f.read(1024*1024), b""):
            h.update(block)
    return h.hexdigest()

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs).stdout

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("model", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--id", type=int, required=True)
    p.add_argument("--key", type=Path, required=True)
    p.add_argument("--cert", type=Path, required=True)
    a = p.parse_args()
    if not 5 <= a.id <= 999999 or a.output.exists() or a.output.resolve() == a.model.resolve():
        raise ValueError("invalid ID or output already exists")
    size = check_model(a.model)
    if sha(a.cert) != CERT:
        raise ValueError("certificate mismatch")
    digest = sha(a.model)
    payload = json.dumps({"schema":1,"package":"com.xs.character.viewer","sourceSha256":SOURCE,"profile":"semantic8","minAppVersion":82,"id":a.id,"size":size,"sha256":digest}, separators=(",",":"), sort_keys=True).encode()
    password = getpass.getpass("Existing signing backup password: ")
    # Password travels on stdin only; the decrypted key never touches disk.
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d/"payload").write_bytes(payload)
        sig = run("openssl","dgst","-sha256","-sign",str(a.key),"-passin","stdin",str(d/"payload"),input=(password+"\n").encode(),stdout=subprocess.PIPE)
        del password
        pub = run("openssl","x509","-inform","DER","-in",str(a.cert),"-pubkey","-noout",stdout=subprocess.PIPE)
        (d/"pub").write_bytes(pub)
        (d/"sig").write_bytes(sig)
        run("openssl","dgst","-sha256","-verify",str(d/"pub"),"-signature",str(d/"sig"),str(d/"payload"),stdout=subprocess.DEVNULL)
    envelope = json.dumps({"payload":base64.b64encode(payload).decode(),"signature":base64.b64encode(sig).decode()},separators=(",",":")).encode()
    a.output.parent.mkdir(parents=True,exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".starling-asset-",dir=a.output.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(name,"w",compression=zipfile.ZIP_STORED,allowZip64=False) as z:
            z.writestr("manifest.json",envelope)
            z.write(a.model,"model.glb")
        with zipfile.ZipFile(name) as z:
            h = hashlib.sha256()
            with z.open("model.glb") as f:
                for block in iter(lambda: f.read(1024*1024), b""):
                    h.update(block)
            if h.hexdigest() != digest or z.getinfo("model.glb").file_size != size:
                raise ValueError("asset changed during packing")
        # Avoid overwriting another file even in a concurrent invocation.
        os.link(name,a.output)
    finally:
        os.unlink(name)
    print(f"Signed asset {a.id}: {a.output} ({a.output.stat().st_size} bytes)")
if __name__ == "__main__":
    main()
