
import zipfile, os, struct
base = r"D:\小肥鱼工作区\07-影音App\qingshu-merge"
z = zipfile.ZipFile(os.path.join(base,'a3.zip'))
out = os.path.join(base,'a3_out')
os.makedirs(out, exist_ok=True)
z.extractall(out)
apk = None
for f in os.listdir(out):
    p = os.path.join(out,f)
    if f.endswith('.apk'):
        apk = p
        print('APK:', f, round(os.path.getsize(p)/1048576,1), 'MB')

if apk:
    zz = zipfile.ZipFile(apk)
    names = zz.namelist()
    sig = [n for n in names if n.startswith('META-INF/') and (n.endswith('.RSA') or n.endswith('.SF'))]
    data = open(apk,'rb').read()
    eocd=-1
    for i in range(len(data)-22, max(0,len(data)-65558), -1):
        if data[i:i+4]==b'PK\x05\x06': eocd=i; break
    cd_off = struct.unpack_from('<I', data, eocd+16)[0]
    has_v2 = data[cd_off-16:cd_off] == b'APK Sig Block 42'
    print('v1 cert:', sig)
    print('v2 block:', has_v2)
    print('INSTALLABLE:', bool(sig) or has_v2)
    # 复制到工作区
    dst = r"D:\小肥鱼工作区\07-影音App\青枢-合并版-v1.0.2.apk"
    import shutil
    shutil.copy2(apk, dst)
    print('copied to:', dst)
