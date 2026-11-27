import base64,hashlib,json,struct,sys,zipfile
from pathlib import Path
m=json.loads(Path("updates/publish.json").read_text())
a=Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(a).hexdigest()==m["inputSha256"]
e=a.rfind(b"PK\x05\x06")
assert e>=0 and e+22+struct.unpack_from("<H",a,e+20)[0]==len(a)
cd=struct.unpack_from("<I",a,e+16)[0]
assert a[cd-16:cd]==b"APK Sig Block 42"
n=struct.unpack_from("<Q",a,cd-24)[0]
start=cd-n-8
assert start>=0 and struct.unpack_from("<Q",a,start)[0]==n
block=base64.b64decode(m["signingBlock"],validate=True)
assert len(block)<65536 and block[-16:]==b"APK Sig Block 42"
pad=int(m.get("padding",0));assert 0<=pad<4096
end=bytearray(a[e:]);struct.pack_into("<I",end,16,start+pad+len(block))
out=a[:start]+bytes(pad)+block+a[cd:e]+end
assert hashlib.sha256(out).hexdigest()==m["outputSha256"]
version=int(m["versionCode"]);assert 33<=version<1000000
dest=Path("updates")/("starling-v%d.apk"%version)
dest.write_bytes(out)
with zipfile.ZipFile(dest) as z:
 assert z.testzip() is None
 assert not any(x.startswith("assets/") and not x.endswith("/") and x not in ("assets/studio-controls.js","assets/studio_ibl.ktx") for x in z.namelist()),"Private assets must not be published"
manifest={"schema":1,"enabled":True,"versionCode":version,"versionName":m["versionName"],"url":"https://raw.githubusercontent.com/xinminyu168-spec/starling-3d-studio/main/"+str(dest),"sha256":m["outputSha256"],"size":len(out)}
Path("app-update.json").write_text(json.dumps(manifest,indent=2)+"\n")
print(dest)
