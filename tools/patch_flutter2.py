p = '/mnt/d/flutter/packages/flutter_tools/lib/src/windows/build_windows.dart'
with open(p, encoding='utf-8') as f:
    c = f.read()
old = """        if (install) ...<String>['--target', 'INSTALL'],"""
new = """        if (install) ...<String>['--target', 'install'],"""
assert old in c, "pattern not found"
c = c.replace(old, new)
with open(p, 'w', encoding='utf-8') as f:
    f.write(c)
print("patched INSTALL -> install")
