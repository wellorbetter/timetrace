/// Pure path presentation shared by asset stores and settings. No environment
/// lookup, directory probing or relative fallback belongs in this leaf.
const diaryDraftTagsAssetSuffix = 'diary-draft-tags-v1';

String? timeTraceStorageLocation(String? base, String suffix) {
  if (base == null || base.contains('\u0000') || suffix.contains('\u0000')) {
    return null;
  }
  final absolute =
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(base) ||
      RegExp(r'^\\\\[^\\/]+[\\/][^\\/]+').hasMatch(base);
  // Suffixes are internal single asset names, never arbitrary traversal paths.
  if (!absolute ||
      suffix.isEmpty ||
      suffix.contains(RegExp(r'[\\/]')) ||
      suffix == '.' ||
      suffix == '..') {
    return null;
  }
  return '${base.replaceFirst(RegExp(r'[\\/]+$'), '')}\\TimeTrace\\$suffix';
}

/// Exact opener target for a known asset: configuration is a file, all other
/// listed assets are directories. String-only; never probes or creates folders.
String? timeTraceStorageFolderLocation(String? base, String suffix) {
  final location = timeTraceStorageLocation(base, suffix);
  if (location == null) return null;
  return suffix == 'ui_config.json'
      ? location.substring(0, location.length - r'\ui_config.json'.length)
      : location;
}
