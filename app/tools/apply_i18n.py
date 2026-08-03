import io

# dashboard_screen i18n
p = 'lib/src/features/dashboard/presentation/dashboard_screen.dart'
with open(p, encoding='utf-8') as f:
    c = f.read()
c = c.replace(
    "import 'package:timetrace_app/src/core/widgets/empty_state.dart';",
    "import 'package:timetrace_app/src/core/i18n/l10n.dart';\nimport 'package:timetrace_app/src/core/widgets/empty_state.dart';"
)
c = c.replace(
    "title: const Text('使用统计'),",
    "title: Text(L10n(ref.watch(localeProvider)).usageStats),"
)
c = c.replace(
    "('今天', DateRange.today),",
    "(L10n(ref.watch(localeProvider)).loc == AppLocale.zh ? '今天' : 'Today', DateRange.today),"
)
with open(p, 'w', encoding='utf-8') as f:
    f.write(c)
print("dashboard i18n ok")

# startup_screen i18n
p = 'lib/src/features/startup/presentation/startup_screen.dart'
with open(p, encoding='utf-8') as f:
    c = f.read()
c = c.replace(
    "import 'package:flutter_riverpod/flutter_riverpod.dart';",
    "import 'package:flutter_riverpod/flutter_riverpod.dart';\nimport 'package:timetrace_app/src/core/i18n/l10n.dart';"
)
old_title = """        title: asyncEntries.maybeWhen(
          data: (entries) =>
              Text('自启动 (\${entries.length}项, \$enabled启用)'),
          orElse: () => const Text('自启动'),
        ),"""
new_title = """        title: asyncEntries.maybeWhen(
          data: (entries) => Text(
              '\${L10n(ref.watch(localeProvider)).startup} (\${entries.length}'
              '\${L10n(ref.watch(localeProvider)).loc == AppLocale.zh ? '项' : ' items'}, \$enabled'
              '\${L10n(ref.watch(localeProvider)).loc == AppLocale.zh ? '启用' : ' enabled'})'),
          orElse: () => Text(L10n(ref.watch(localeProvider)).startup),
        ),"""
if old_title in c:
    c = c.replace(old_title, new_title)
else:
    print("WARN: startup title pattern not found, checking...")
    idx = c.find('自启动 (')
    print("ctx:", repr(c[max(0,idx-50):idx+80]) if idx > 0 else "not found")
c = c.replace(
    "tooltip: '重新扫描',",
    "tooltip: L10n(ref.watch(localeProvider)).loc == AppLocale.zh ? '重新扫描' : 'Rescan',"
)
with open(p, 'w', encoding='utf-8') as f:
    f.write(c)
print("startup i18n ok")
