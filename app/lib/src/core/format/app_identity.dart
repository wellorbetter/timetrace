/// Presentation-only aliases; stored attribution identifiers remain unchanged.
String appIdentityKey(String value) {
  final key = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\.exe$'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
  if (key == 'msedge' || key == 'edge' || key == 'microsoftedge') {
    return 'edge';
  }
  if (key == 'windowsterminal' ||
      key == 'wt' ||
      key == 'windowsterminalpreview') {
    return 'windowsterminal';
  }
  if (key == 'leagueclientux' ||
      key == 'leagueclient' ||
      key.startsWith('leagueoflegends') ||
      key == '英雄联盟') {
    return 'leagueoflegends';
  }
  return key;
}

String appDisplayLabel(String value) => switch (appIdentityKey(value)) {
  'edge' => 'Microsoft Edge',
  'leagueoflegends' => '英雄联盟',
  'windowsterminal' => 'Windows Terminal',
  'cmd' => '命令提示符',
  _ => value,
};

bool isTerminalApp(String value) => const {
  'windowsterminal',
  'cmd',
  'powershell',
  'pwsh',
}.contains(appIdentityKey(value));
