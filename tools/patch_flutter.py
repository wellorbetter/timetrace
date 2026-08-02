p = r'/mnt/d/flutter/packages/flutter_tools/lib/src/windows/build_windows.dart'
with open(p, encoding='utf-8') as f:
    c = f.read()
old = """    result = await globals.processUtils.stream(<String>[
      cmakePath,
      '-S',
      sourceDir.path,
      '-B',
      buildDir.path,
      '-G',
      generator,
      '-A',
      getCmakeWindowsArch(targetPlatform),
      '-DFLUTTER_TARGET_PLATFORM=${getNameForTargetPlatform(targetPlatform)}',
    ], trace: true);"""
new = """    final List<String> genArgs = <String>[
      cmakePath,
      '-S',
      sourceDir.path,
      '-B',
      buildDir.path,
      '-G',
      generator,
    ];
    // Ninja has no platform spec; VS generators need -A.
    if (generator != 'Ninja') {
      genArgs.addAll(<String>['-A', getCmakeWindowsArch(targetPlatform)]);
    }
    genArgs.add('-DFLUTTER_TARGET_PLATFORM=' + getNameForTargetPlatform(targetPlatform));
    result = await globals.processUtils.stream(genArgs, trace: true);"""
assert old in c, "pattern not found"
c = c.replace(old, new)
with open(p, 'w', encoding='utf-8') as f:
    f.write(c)
print("patched build_windows for Ninja")
