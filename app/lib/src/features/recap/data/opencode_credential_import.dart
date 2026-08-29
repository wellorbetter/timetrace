import 'dart:convert';
import 'dart:io';

/// Read-only bridge for reusing an API key the user has already added to
/// OpenCode. Nothing is read until the user explicitly presses the import
/// action in TimeTrace, and the imported key is kept in RecapAiSettings'
/// runtime-only field (never serialized by TimeTrace).
class OpenCodeCredentialImport {
  const OpenCodeCredentialImport();

  String? get authPath {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null || home.trim().isEmpty) return null;
    return '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share${Platform.pathSeparator}opencode${Platform.pathSeparator}auth.json';
  }

  Future<String?> readApiKey(String providerId) async {
    final path = authPath;
    if (path == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final credential = decoded[providerId];
      if (credential is! Map<String, dynamic>) return null;
      if (credential['type'] != 'api') return null;
      final key = credential['key'];
      if (key is! String || key.trim().isEmpty) return null;
      return key.trim();
    } catch (_) {
      return null;
    }
  }
}
