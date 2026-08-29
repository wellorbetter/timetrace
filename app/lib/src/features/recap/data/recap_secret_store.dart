import 'dart:io';

import 'package:timetrace_app/src/core/platform_paths.dart';

/// Stores the user-entered AI API key outside recap_ai.json.
///
/// Windows uses per-user DPAPI encryption, macOS uses Keychain, and Linux uses
/// Secret Service through `secret-tool` when available. If a platform credential
/// backend is unavailable, the caller simply gets an empty key and can still use
/// an environment variable or the current in-memory value.
class RecapSecretStore {
  const RecapSecretStore._();

  static const _service = 'com.timetrace.ai-recap';
  static String get _windowsBlob => PlatformPaths.child('recap_ai_key.dpapi');

  static Future<String> load() async {
    try {
      if (Platform.isWindows) return await _loadWindows();
      if (Platform.isMacOS) return await _loadMacOS();
      if (Platform.isLinux) return await _loadLinux();
    } catch (_) {}
    return '';
  }

  static Future<bool> save(String secret) async {
    try {
      if (Platform.isWindows) return await _saveWindows(secret);
      if (Platform.isMacOS) return await _saveMacOS(secret);
      if (Platform.isLinux) return await _saveLinux(secret);
    } catch (_) {}
    return false;
  }

  static Future<String> _loadWindows() async {
    final file = File(_windowsBlob);
    if (!await file.exists()) return '';
    final path = _psQuote(file.path);
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$s = Get-Content -Raw '$path' | ConvertTo-SecureString; "
            "[System.Net.NetworkCredential]::new('', \$s).Password",
      ],
    );
    return result.exitCode == 0 ? result.stdout.toString().trim() : '';
  }

  static Future<bool> _saveWindows(String secret) async {
    PlatformPaths.ensureDirectory();
    final file = File(_windowsBlob);
    if (secret.isEmpty) {
      if (await file.exists()) await file.delete();
      return true;
    }
    final path = _psQuote(file.path);
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$s = ConvertTo-SecureString \$env:TIMETRACE_AI_SECRET -AsPlainText -Force; "
            "ConvertFrom-SecureString \$s | Set-Content -NoNewline '$path'",
      ],
      environment: {...Platform.environment, 'TIMETRACE_AI_SECRET': secret},
    );
    return result.exitCode == 0;
  }

  static Future<String> _loadMacOS() async {
    final result = await Process.run('security', [
      'find-generic-password',
      '-a',
      'TimeTrace',
      '-s',
      _service,
      '-w',
    ]);
    return result.exitCode == 0 ? result.stdout.toString().trim() : '';
  }

  static Future<bool> _saveMacOS(String secret) async {
    if (secret.isEmpty) {
      await Process.run('security', [
        'delete-generic-password',
        '-a',
        'TimeTrace',
        '-s',
        _service,
      ]);
      return true;
    }
    final result = await Process.run('security', [
      'add-generic-password',
      '-U',
      '-a',
      'TimeTrace',
      '-s',
      _service,
      '-w',
      secret,
    ]);
    return result.exitCode == 0;
  }

  static Future<String> _loadLinux() async {
    if (!await _hasSecretTool()) return '';
    final result = await Process.run('secret-tool', [
      'lookup',
      'service',
      'timetrace',
      'kind',
      'recap-ai',
    ]);
    return result.exitCode == 0 ? result.stdout.toString().trim() : '';
  }

  static Future<bool> _saveLinux(String secret) async {
    if (!await _hasSecretTool()) return false;
    if (secret.isEmpty) {
      final result = await Process.run('secret-tool', [
        'clear',
        'service',
        'timetrace',
        'kind',
        'recap-ai',
      ]);
      return result.exitCode == 0;
    }
    final process = await Process.start('secret-tool', [
      'store',
      '--label=TimeTrace AI Recap',
      'service',
      'timetrace',
      'kind',
      'recap-ai',
    ]);
    process.stdin.write(secret);
    await process.stdin.close();
    return (await process.exitCode) == 0;
  }

  static Future<bool> _hasSecretTool() async {
    final result = await Process.run(
      'sh',
      ['-c', 'command -v secret-tool >/dev/null 2>&1'],
    );
    return result.exitCode == 0;
  }

  static String _psQuote(String value) => value.replaceAll("'", "''");
}
