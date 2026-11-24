
import re
def deps(path):
    txt = open(path, encoding='utf-8').read()
    m = re.search(r'^dependencies:(.*?)^dev_dependencies:', txt, re.S|re.M)
    if not m: m = re.search(r'^dependencies:(.*)', txt, re.S|re.M)
    body = m.group(1) if m else ''
    out = {}
    for line in body.splitlines():
        mm = re.match(r'^  ([a-z_0-9]+):\s*(.*)$', line)
        if mm:
            out[mm.group(1)] = mm.group(2).strip()
    return out
main = deps(r"D:\小肥鱼工作区\07-影音App\qingshu-merge\pubspec.yaml")
emb  = deps(r"D:\小肥鱼工作区\07-影音App\qingshu-merge\packages\kazumi\pubspec.yaml")
print('主项目依赖数:', len(main), '| 内嵌包:', len(emb))
print()
print('=== 同名依赖版本差异 ===')
diff=0
for k in sorted(set(main) & set(emb)):
    a, b = main[k], emb[k]
    if a != b:
        print(f'  {k:<32} main={a!r:<22} emb={b!r}')
        diff+=1
print(f'  差异 {diff} 项')
print()
print('=== 内嵌包独有（主项目没有，需确认能解析） ===')
for k in sorted(set(emb)-set(main)):
    print(f'  {k}: {emb[k]}')
