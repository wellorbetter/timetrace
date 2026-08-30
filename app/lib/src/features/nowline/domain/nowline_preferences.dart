enum NowlinePlacement { top, center, bottom }

class NowlinePreferences {
  const NowlinePreferences({
    this.lineCount = 4,
    this.panelOpacity = 0.82,
    this.showWindowTitles = false,
    this.showTimestamps = true,
    this.clickThroughOnStart = false,
    this.placement = NowlinePlacement.bottom,
  });

  final int lineCount;
  final double panelOpacity;

  /// Window titles can contain document names and private page titles. They are
  /// therefore hidden until the user explicitly enables them.
  final bool showWindowTitles;
  final bool showTimestamps;
  final bool clickThroughOnStart;
  final NowlinePlacement placement;

  NowlinePreferences copyWith({
    int? lineCount,
    double? panelOpacity,
    bool? showWindowTitles,
    bool? showTimestamps,
    bool? clickThroughOnStart,
    NowlinePlacement? placement,
  }) => NowlinePreferences(
    lineCount: lineCount ?? this.lineCount,
    panelOpacity: panelOpacity ?? this.panelOpacity,
    showWindowTitles: showWindowTitles ?? this.showWindowTitles,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    clickThroughOnStart: clickThroughOnStart ?? this.clickThroughOnStart,
    placement: placement ?? this.placement,
  );

  Map<String, Object> toJson() => {
    'line_count': lineCount,
    'panel_opacity': panelOpacity,
    'show_window_titles': showWindowTitles,
    'show_timestamps': showTimestamps,
    'click_through_on_start': clickThroughOnStart,
    'placement': placement.name,
  };

  factory NowlinePreferences.fromJson(Map<String, Object?> json) {
    final rawLineCount = (json['line_count'] as num?)?.toInt() ?? 4;
    final rawOpacity = (json['panel_opacity'] as num?)?.toDouble() ?? 0.82;
    final placementName = json['placement'] as String?;
    return NowlinePreferences(
      lineCount: rawLineCount.clamp(2, 6).toInt(),
      panelOpacity: rawOpacity.clamp(0.5, 0.96).toDouble(),
      showWindowTitles: json['show_window_titles'] == true,
      showTimestamps: json['show_timestamps'] != false,
      clickThroughOnStart: json['click_through_on_start'] == true,
      placement: NowlinePlacement.values.firstWhere(
        (value) => value.name == placementName,
        orElse: () => NowlinePlacement.bottom,
      ),
    );
  }
}
