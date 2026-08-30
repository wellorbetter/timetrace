// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$PomodoroSettings {

 bool get enabled; int get focusMinutes; int get shortBreakMinutes; int get longBreakMinutes; int get longBreakInterval; bool get autoStartNext; bool get notificationsEnabled; bool get notificationSound;
/// Create a copy of PomodoroSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PomodoroSettingsCopyWith<PomodoroSettings> get copyWith => _$PomodoroSettingsCopyWithImpl<PomodoroSettings>(this as PomodoroSettings, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PomodoroSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.focusMinutes, focusMinutes) || other.focusMinutes == focusMinutes)&&(identical(other.shortBreakMinutes, shortBreakMinutes) || other.shortBreakMinutes == shortBreakMinutes)&&(identical(other.longBreakMinutes, longBreakMinutes) || other.longBreakMinutes == longBreakMinutes)&&(identical(other.longBreakInterval, longBreakInterval) || other.longBreakInterval == longBreakInterval)&&(identical(other.autoStartNext, autoStartNext) || other.autoStartNext == autoStartNext)&&(identical(other.notificationsEnabled, notificationsEnabled) || other.notificationsEnabled == notificationsEnabled)&&(identical(other.notificationSound, notificationSound) || other.notificationSound == notificationSound));
}


@override
int get hashCode => Object.hash(runtimeType,enabled,focusMinutes,shortBreakMinutes,longBreakMinutes,longBreakInterval,autoStartNext,notificationsEnabled,notificationSound);

@override
String toString() {
  return 'PomodoroSettings(enabled: $enabled, focusMinutes: $focusMinutes, shortBreakMinutes: $shortBreakMinutes, longBreakMinutes: $longBreakMinutes, longBreakInterval: $longBreakInterval, autoStartNext: $autoStartNext, notificationsEnabled: $notificationsEnabled, notificationSound: $notificationSound)';
}


}

/// @nodoc
abstract mixin class $PomodoroSettingsCopyWith<$Res>  {
  factory $PomodoroSettingsCopyWith(PomodoroSettings value, $Res Function(PomodoroSettings) _then) = _$PomodoroSettingsCopyWithImpl;
@useResult
$Res call({
 bool enabled, int focusMinutes, int shortBreakMinutes, int longBreakMinutes, int longBreakInterval, bool autoStartNext, bool notificationsEnabled, bool notificationSound
});




}
/// @nodoc
class _$PomodoroSettingsCopyWithImpl<$Res>
    implements $PomodoroSettingsCopyWith<$Res> {
  _$PomodoroSettingsCopyWithImpl(this._self, this._then);

  final PomodoroSettings _self;
  final $Res Function(PomodoroSettings) _then;

/// Create a copy of PomodoroSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? enabled = null,Object? focusMinutes = null,Object? shortBreakMinutes = null,Object? longBreakMinutes = null,Object? longBreakInterval = null,Object? autoStartNext = null,Object? notificationsEnabled = null,Object? notificationSound = null,}) {
  return _then(_self.copyWith(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,focusMinutes: null == focusMinutes ? _self.focusMinutes : focusMinutes // ignore: cast_nullable_to_non_nullable
as int,shortBreakMinutes: null == shortBreakMinutes ? _self.shortBreakMinutes : shortBreakMinutes // ignore: cast_nullable_to_non_nullable
as int,longBreakMinutes: null == longBreakMinutes ? _self.longBreakMinutes : longBreakMinutes // ignore: cast_nullable_to_non_nullable
as int,longBreakInterval: null == longBreakInterval ? _self.longBreakInterval : longBreakInterval // ignore: cast_nullable_to_non_nullable
as int,autoStartNext: null == autoStartNext ? _self.autoStartNext : autoStartNext // ignore: cast_nullable_to_non_nullable
as bool,notificationsEnabled: null == notificationsEnabled ? _self.notificationsEnabled : notificationsEnabled // ignore: cast_nullable_to_non_nullable
as bool,notificationSound: null == notificationSound ? _self.notificationSound : notificationSound // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [PomodoroSettings].
extension PomodoroSettingsPatterns on PomodoroSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PomodoroSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PomodoroSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PomodoroSettings value)  $default,){
final _that = this;
switch (_that) {
case _PomodoroSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PomodoroSettings value)?  $default,){
final _that = this;
switch (_that) {
case _PomodoroSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool enabled,  int focusMinutes,  int shortBreakMinutes,  int longBreakMinutes,  int longBreakInterval,  bool autoStartNext,  bool notificationsEnabled,  bool notificationSound)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PomodoroSettings() when $default != null:
return $default(_that.enabled,_that.focusMinutes,_that.shortBreakMinutes,_that.longBreakMinutes,_that.longBreakInterval,_that.autoStartNext,_that.notificationsEnabled,_that.notificationSound);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool enabled,  int focusMinutes,  int shortBreakMinutes,  int longBreakMinutes,  int longBreakInterval,  bool autoStartNext,  bool notificationsEnabled,  bool notificationSound)  $default,) {final _that = this;
switch (_that) {
case _PomodoroSettings():
return $default(_that.enabled,_that.focusMinutes,_that.shortBreakMinutes,_that.longBreakMinutes,_that.longBreakInterval,_that.autoStartNext,_that.notificationsEnabled,_that.notificationSound);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool enabled,  int focusMinutes,  int shortBreakMinutes,  int longBreakMinutes,  int longBreakInterval,  bool autoStartNext,  bool notificationsEnabled,  bool notificationSound)?  $default,) {final _that = this;
switch (_that) {
case _PomodoroSettings() when $default != null:
return $default(_that.enabled,_that.focusMinutes,_that.shortBreakMinutes,_that.longBreakMinutes,_that.longBreakInterval,_that.autoStartNext,_that.notificationsEnabled,_that.notificationSound);case _:
  return null;

}
}

}

/// @nodoc


class _PomodoroSettings extends PomodoroSettings {
  const _PomodoroSettings({required this.enabled, required this.focusMinutes, required this.shortBreakMinutes, required this.longBreakMinutes, required this.longBreakInterval, required this.autoStartNext, required this.notificationsEnabled, required this.notificationSound}): super._();


@override final  bool enabled;
@override final  int focusMinutes;
@override final  int shortBreakMinutes;
@override final  int longBreakMinutes;
@override final  int longBreakInterval;
@override final  bool autoStartNext;
@override final  bool notificationsEnabled;
@override final  bool notificationSound;

/// Create a copy of PomodoroSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PomodoroSettingsCopyWith<_PomodoroSettings> get copyWith => __$PomodoroSettingsCopyWithImpl<_PomodoroSettings>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PomodoroSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.focusMinutes, focusMinutes) || other.focusMinutes == focusMinutes)&&(identical(other.shortBreakMinutes, shortBreakMinutes) || other.shortBreakMinutes == shortBreakMinutes)&&(identical(other.longBreakMinutes, longBreakMinutes) || other.longBreakMinutes == longBreakMinutes)&&(identical(other.longBreakInterval, longBreakInterval) || other.longBreakInterval == longBreakInterval)&&(identical(other.autoStartNext, autoStartNext) || other.autoStartNext == autoStartNext)&&(identical(other.notificationsEnabled, notificationsEnabled) || other.notificationsEnabled == notificationsEnabled)&&(identical(other.notificationSound, notificationSound) || other.notificationSound == notificationSound));
}


@override
int get hashCode => Object.hash(runtimeType,enabled,focusMinutes,shortBreakMinutes,longBreakMinutes,longBreakInterval,autoStartNext,notificationsEnabled,notificationSound);

@override
String toString() {
  return 'PomodoroSettings(enabled: $enabled, focusMinutes: $focusMinutes, shortBreakMinutes: $shortBreakMinutes, longBreakMinutes: $longBreakMinutes, longBreakInterval: $longBreakInterval, autoStartNext: $autoStartNext, notificationsEnabled: $notificationsEnabled, notificationSound: $notificationSound)';
}


}

/// @nodoc
abstract mixin class _$PomodoroSettingsCopyWith<$Res> implements $PomodoroSettingsCopyWith<$Res> {
  factory _$PomodoroSettingsCopyWith(_PomodoroSettings value, $Res Function(_PomodoroSettings) _then) = __$PomodoroSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool enabled, int focusMinutes, int shortBreakMinutes, int longBreakMinutes, int longBreakInterval, bool autoStartNext, bool notificationsEnabled, bool notificationSound
});




}
/// @nodoc
class __$PomodoroSettingsCopyWithImpl<$Res>
    implements _$PomodoroSettingsCopyWith<$Res> {
  __$PomodoroSettingsCopyWithImpl(this._self, this._then);

  final _PomodoroSettings _self;
  final $Res Function(_PomodoroSettings) _then;

/// Create a copy of PomodoroSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? enabled = null,Object? focusMinutes = null,Object? shortBreakMinutes = null,Object? longBreakMinutes = null,Object? longBreakInterval = null,Object? autoStartNext = null,Object? notificationsEnabled = null,Object? notificationSound = null,}) {
  return _then(_PomodoroSettings(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,focusMinutes: null == focusMinutes ? _self.focusMinutes : focusMinutes // ignore: cast_nullable_to_non_nullable
as int,shortBreakMinutes: null == shortBreakMinutes ? _self.shortBreakMinutes : shortBreakMinutes // ignore: cast_nullable_to_non_nullable
as int,longBreakMinutes: null == longBreakMinutes ? _self.longBreakMinutes : longBreakMinutes // ignore: cast_nullable_to_non_nullable
as int,longBreakInterval: null == longBreakInterval ? _self.longBreakInterval : longBreakInterval // ignore: cast_nullable_to_non_nullable
as int,autoStartNext: null == autoStartNext ? _self.autoStartNext : autoStartNext // ignore: cast_nullable_to_non_nullable
as bool,notificationsEnabled: null == notificationsEnabled ? _self.notificationsEnabled : notificationsEnabled // ignore: cast_nullable_to_non_nullable
as bool,notificationSound: null == notificationSound ? _self.notificationSound : notificationSound // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$AppTimeoutSettings {

 bool get enabled; int get defaultThresholdMinutes; int get defaultCooldownMinutes; bool get notificationsEnabled; bool get notificationSound;
/// Create a copy of AppTimeoutSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppTimeoutSettingsCopyWith<AppTimeoutSettings> get copyWith => _$AppTimeoutSettingsCopyWithImpl<AppTimeoutSettings>(this as AppTimeoutSettings, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppTimeoutSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.defaultThresholdMinutes, defaultThresholdMinutes) || other.defaultThresholdMinutes == defaultThresholdMinutes)&&(identical(other.defaultCooldownMinutes, defaultCooldownMinutes) || other.defaultCooldownMinutes == defaultCooldownMinutes)&&(identical(other.notificationsEnabled, notificationsEnabled) || other.notificationsEnabled == notificationsEnabled)&&(identical(other.notificationSound, notificationSound) || other.notificationSound == notificationSound));
}


@override
int get hashCode => Object.hash(runtimeType,enabled,defaultThresholdMinutes,defaultCooldownMinutes,notificationsEnabled,notificationSound);

@override
String toString() {
  return 'AppTimeoutSettings(enabled: $enabled, defaultThresholdMinutes: $defaultThresholdMinutes, defaultCooldownMinutes: $defaultCooldownMinutes, notificationsEnabled: $notificationsEnabled, notificationSound: $notificationSound)';
}


}

/// @nodoc
abstract mixin class $AppTimeoutSettingsCopyWith<$Res>  {
  factory $AppTimeoutSettingsCopyWith(AppTimeoutSettings value, $Res Function(AppTimeoutSettings) _then) = _$AppTimeoutSettingsCopyWithImpl;
@useResult
$Res call({
 bool enabled, int defaultThresholdMinutes, int defaultCooldownMinutes, bool notificationsEnabled, bool notificationSound
});




}
/// @nodoc
class _$AppTimeoutSettingsCopyWithImpl<$Res>
    implements $AppTimeoutSettingsCopyWith<$Res> {
  _$AppTimeoutSettingsCopyWithImpl(this._self, this._then);

  final AppTimeoutSettings _self;
  final $Res Function(AppTimeoutSettings) _then;

/// Create a copy of AppTimeoutSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? enabled = null,Object? defaultThresholdMinutes = null,Object? defaultCooldownMinutes = null,Object? notificationsEnabled = null,Object? notificationSound = null,}) {
  return _then(_self.copyWith(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,defaultThresholdMinutes: null == defaultThresholdMinutes ? _self.defaultThresholdMinutes : defaultThresholdMinutes // ignore: cast_nullable_to_non_nullable
as int,defaultCooldownMinutes: null == defaultCooldownMinutes ? _self.defaultCooldownMinutes : defaultCooldownMinutes // ignore: cast_nullable_to_non_nullable
as int,notificationsEnabled: null == notificationsEnabled ? _self.notificationsEnabled : notificationsEnabled // ignore: cast_nullable_to_non_nullable
as bool,notificationSound: null == notificationSound ? _self.notificationSound : notificationSound // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [AppTimeoutSettings].
extension AppTimeoutSettingsPatterns on AppTimeoutSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppTimeoutSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppTimeoutSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppTimeoutSettings value)  $default,){
final _that = this;
switch (_that) {
case _AppTimeoutSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppTimeoutSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AppTimeoutSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool enabled,  int defaultThresholdMinutes,  int defaultCooldownMinutes,  bool notificationsEnabled,  bool notificationSound)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppTimeoutSettings() when $default != null:
return $default(_that.enabled,_that.defaultThresholdMinutes,_that.defaultCooldownMinutes,_that.notificationsEnabled,_that.notificationSound);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool enabled,  int defaultThresholdMinutes,  int defaultCooldownMinutes,  bool notificationsEnabled,  bool notificationSound)  $default,) {final _that = this;
switch (_that) {
case _AppTimeoutSettings():
return $default(_that.enabled,_that.defaultThresholdMinutes,_that.defaultCooldownMinutes,_that.notificationsEnabled,_that.notificationSound);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool enabled,  int defaultThresholdMinutes,  int defaultCooldownMinutes,  bool notificationsEnabled,  bool notificationSound)?  $default,) {final _that = this;
switch (_that) {
case _AppTimeoutSettings() when $default != null:
return $default(_that.enabled,_that.defaultThresholdMinutes,_that.defaultCooldownMinutes,_that.notificationsEnabled,_that.notificationSound);case _:
  return null;

}
}

}

/// @nodoc


class _AppTimeoutSettings extends AppTimeoutSettings {
  const _AppTimeoutSettings({required this.enabled, required this.defaultThresholdMinutes, required this.defaultCooldownMinutes, required this.notificationsEnabled, required this.notificationSound}): super._();


@override final  bool enabled;
@override final  int defaultThresholdMinutes;
@override final  int defaultCooldownMinutes;
@override final  bool notificationsEnabled;
@override final  bool notificationSound;

/// Create a copy of AppTimeoutSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppTimeoutSettingsCopyWith<_AppTimeoutSettings> get copyWith => __$AppTimeoutSettingsCopyWithImpl<_AppTimeoutSettings>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppTimeoutSettings&&(identical(other.enabled, enabled) || other.enabled == enabled)&&(identical(other.defaultThresholdMinutes, defaultThresholdMinutes) || other.defaultThresholdMinutes == defaultThresholdMinutes)&&(identical(other.defaultCooldownMinutes, defaultCooldownMinutes) || other.defaultCooldownMinutes == defaultCooldownMinutes)&&(identical(other.notificationsEnabled, notificationsEnabled) || other.notificationsEnabled == notificationsEnabled)&&(identical(other.notificationSound, notificationSound) || other.notificationSound == notificationSound));
}


@override
int get hashCode => Object.hash(runtimeType,enabled,defaultThresholdMinutes,defaultCooldownMinutes,notificationsEnabled,notificationSound);

@override
String toString() {
  return 'AppTimeoutSettings(enabled: $enabled, defaultThresholdMinutes: $defaultThresholdMinutes, defaultCooldownMinutes: $defaultCooldownMinutes, notificationsEnabled: $notificationsEnabled, notificationSound: $notificationSound)';
}


}

/// @nodoc
abstract mixin class _$AppTimeoutSettingsCopyWith<$Res> implements $AppTimeoutSettingsCopyWith<$Res> {
  factory _$AppTimeoutSettingsCopyWith(_AppTimeoutSettings value, $Res Function(_AppTimeoutSettings) _then) = __$AppTimeoutSettingsCopyWithImpl;
@override @useResult
$Res call({
 bool enabled, int defaultThresholdMinutes, int defaultCooldownMinutes, bool notificationsEnabled, bool notificationSound
});




}
/// @nodoc
class __$AppTimeoutSettingsCopyWithImpl<$Res>
    implements _$AppTimeoutSettingsCopyWith<$Res> {
  __$AppTimeoutSettingsCopyWithImpl(this._self, this._then);

  final _AppTimeoutSettings _self;
  final $Res Function(_AppTimeoutSettings) _then;

/// Create a copy of AppTimeoutSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? enabled = null,Object? defaultThresholdMinutes = null,Object? defaultCooldownMinutes = null,Object? notificationsEnabled = null,Object? notificationSound = null,}) {
  return _then(_AppTimeoutSettings(
enabled: null == enabled ? _self.enabled : enabled // ignore: cast_nullable_to_non_nullable
as bool,defaultThresholdMinutes: null == defaultThresholdMinutes ? _self.defaultThresholdMinutes : defaultThresholdMinutes // ignore: cast_nullable_to_non_nullable
as int,defaultCooldownMinutes: null == defaultCooldownMinutes ? _self.defaultCooldownMinutes : defaultCooldownMinutes // ignore: cast_nullable_to_non_nullable
as int,notificationsEnabled: null == notificationsEnabled ? _self.notificationsEnabled : notificationsEnabled // ignore: cast_nullable_to_non_nullable
as bool,notificationSound: null == notificationSound ? _self.notificationSound : notificationSound // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$AppSettings {

 int get pollIntervalMs; int get idleThresholdMinutes; bool get minimizeToTray; bool get startMinimized; bool get autoStartTracking; List<String> get excludedApps; String get dbPath; PomodoroSettings get pomodoro; AppTimeoutSettings get appTimeout;
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppSettingsCopyWith<AppSettings> get copyWith => _$AppSettingsCopyWithImpl<AppSettings>(this as AppSettings, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppSettings&&(identical(other.pollIntervalMs, pollIntervalMs) || other.pollIntervalMs == pollIntervalMs)&&(identical(other.idleThresholdMinutes, idleThresholdMinutes) || other.idleThresholdMinutes == idleThresholdMinutes)&&(identical(other.minimizeToTray, minimizeToTray) || other.minimizeToTray == minimizeToTray)&&(identical(other.startMinimized, startMinimized) || other.startMinimized == startMinimized)&&(identical(other.autoStartTracking, autoStartTracking) || other.autoStartTracking == autoStartTracking)&&const DeepCollectionEquality().equals(other.excludedApps, excludedApps)&&(identical(other.dbPath, dbPath) || other.dbPath == dbPath)&&(identical(other.pomodoro, pomodoro) || other.pomodoro == pomodoro)&&(identical(other.appTimeout, appTimeout) || other.appTimeout == appTimeout));
}


@override
int get hashCode => Object.hash(runtimeType,pollIntervalMs,idleThresholdMinutes,minimizeToTray,startMinimized,autoStartTracking,const DeepCollectionEquality().hash(excludedApps),dbPath,pomodoro,appTimeout);

@override
String toString() {
  return 'AppSettings(pollIntervalMs: $pollIntervalMs, idleThresholdMinutes: $idleThresholdMinutes, minimizeToTray: $minimizeToTray, startMinimized: $startMinimized, autoStartTracking: $autoStartTracking, excludedApps: $excludedApps, dbPath: $dbPath, pomodoro: $pomodoro, appTimeout: $appTimeout)';
}


}

/// @nodoc
abstract mixin class $AppSettingsCopyWith<$Res>  {
  factory $AppSettingsCopyWith(AppSettings value, $Res Function(AppSettings) _then) = _$AppSettingsCopyWithImpl;
@useResult
$Res call({
 int pollIntervalMs, int idleThresholdMinutes, bool minimizeToTray, bool startMinimized, bool autoStartTracking, List<String> excludedApps, String dbPath, PomodoroSettings pomodoro, AppTimeoutSettings appTimeout
});


$PomodoroSettingsCopyWith<$Res> get pomodoro;$AppTimeoutSettingsCopyWith<$Res> get appTimeout;

}
/// @nodoc
class _$AppSettingsCopyWithImpl<$Res>
    implements $AppSettingsCopyWith<$Res> {
  _$AppSettingsCopyWithImpl(this._self, this._then);

  final AppSettings _self;
  final $Res Function(AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? pollIntervalMs = null,Object? idleThresholdMinutes = null,Object? minimizeToTray = null,Object? startMinimized = null,Object? autoStartTracking = null,Object? excludedApps = null,Object? dbPath = null,Object? pomodoro = null,Object? appTimeout = null,}) {
  return _then(_self.copyWith(
pollIntervalMs: null == pollIntervalMs ? _self.pollIntervalMs : pollIntervalMs // ignore: cast_nullable_to_non_nullable
as int,idleThresholdMinutes: null == idleThresholdMinutes ? _self.idleThresholdMinutes : idleThresholdMinutes // ignore: cast_nullable_to_non_nullable
as int,minimizeToTray: null == minimizeToTray ? _self.minimizeToTray : minimizeToTray // ignore: cast_nullable_to_non_nullable
as bool,startMinimized: null == startMinimized ? _self.startMinimized : startMinimized // ignore: cast_nullable_to_non_nullable
as bool,autoStartTracking: null == autoStartTracking ? _self.autoStartTracking : autoStartTracking // ignore: cast_nullable_to_non_nullable
as bool,excludedApps: null == excludedApps ? _self.excludedApps : excludedApps // ignore: cast_nullable_to_non_nullable
as List<String>,dbPath: null == dbPath ? _self.dbPath : dbPath // ignore: cast_nullable_to_non_nullable
as String,pomodoro: null == pomodoro ? _self.pomodoro : pomodoro // ignore: cast_nullable_to_non_nullable
as PomodoroSettings,appTimeout: null == appTimeout ? _self.appTimeout : appTimeout // ignore: cast_nullable_to_non_nullable
as AppTimeoutSettings,
  ));
}
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PomodoroSettingsCopyWith<$Res> get pomodoro {

  return $PomodoroSettingsCopyWith<$Res>(_self.pomodoro, (value) {
    return _then(_self.copyWith(pomodoro: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AppTimeoutSettingsCopyWith<$Res> get appTimeout {

  return $AppTimeoutSettingsCopyWith<$Res>(_self.appTimeout, (value) {
    return _then(_self.copyWith(appTimeout: value));
  });
}
}


/// Adds pattern-matching-related methods to [AppSettings].
extension AppSettingsPatterns on AppSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppSettings value)  $default,){
final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int pollIntervalMs,  int idleThresholdMinutes,  bool minimizeToTray,  bool startMinimized,  bool autoStartTracking,  List<String> excludedApps,  String dbPath,  PomodoroSettings pomodoro,  AppTimeoutSettings appTimeout)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.pollIntervalMs,_that.idleThresholdMinutes,_that.minimizeToTray,_that.startMinimized,_that.autoStartTracking,_that.excludedApps,_that.dbPath,_that.pomodoro,_that.appTimeout);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int pollIntervalMs,  int idleThresholdMinutes,  bool minimizeToTray,  bool startMinimized,  bool autoStartTracking,  List<String> excludedApps,  String dbPath,  PomodoroSettings pomodoro,  AppTimeoutSettings appTimeout)  $default,) {final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that.pollIntervalMs,_that.idleThresholdMinutes,_that.minimizeToTray,_that.startMinimized,_that.autoStartTracking,_that.excludedApps,_that.dbPath,_that.pomodoro,_that.appTimeout);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int pollIntervalMs,  int idleThresholdMinutes,  bool minimizeToTray,  bool startMinimized,  bool autoStartTracking,  List<String> excludedApps,  String dbPath,  PomodoroSettings pomodoro,  AppTimeoutSettings appTimeout)?  $default,) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.pollIntervalMs,_that.idleThresholdMinutes,_that.minimizeToTray,_that.startMinimized,_that.autoStartTracking,_that.excludedApps,_that.dbPath,_that.pomodoro,_that.appTimeout);case _:
  return null;

}
}

}

/// @nodoc


class _AppSettings extends AppSettings {
  const _AppSettings({required this.pollIntervalMs, required this.idleThresholdMinutes, required this.minimizeToTray, required this.startMinimized, required this.autoStartTracking, required final  List<String> excludedApps, required this.dbPath, required this.pomodoro, required this.appTimeout}): _excludedApps = excludedApps,super._();


@override final  int pollIntervalMs;
@override final  int idleThresholdMinutes;
@override final  bool minimizeToTray;
@override final  bool startMinimized;
@override final  bool autoStartTracking;
 final  List<String> _excludedApps;
@override List<String> get excludedApps {
  if (_excludedApps is EqualUnmodifiableListView) return _excludedApps;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_excludedApps);
}

@override final  String dbPath;
@override final  PomodoroSettings pomodoro;
@override final  AppTimeoutSettings appTimeout;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppSettingsCopyWith<_AppSettings> get copyWith => __$AppSettingsCopyWithImpl<_AppSettings>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppSettings&&(identical(other.pollIntervalMs, pollIntervalMs) || other.pollIntervalMs == pollIntervalMs)&&(identical(other.idleThresholdMinutes, idleThresholdMinutes) || other.idleThresholdMinutes == idleThresholdMinutes)&&(identical(other.minimizeToTray, minimizeToTray) || other.minimizeToTray == minimizeToTray)&&(identical(other.startMinimized, startMinimized) || other.startMinimized == startMinimized)&&(identical(other.autoStartTracking, autoStartTracking) || other.autoStartTracking == autoStartTracking)&&const DeepCollectionEquality().equals(other._excludedApps, _excludedApps)&&(identical(other.dbPath, dbPath) || other.dbPath == dbPath)&&(identical(other.pomodoro, pomodoro) || other.pomodoro == pomodoro)&&(identical(other.appTimeout, appTimeout) || other.appTimeout == appTimeout));
}


@override
int get hashCode => Object.hash(runtimeType,pollIntervalMs,idleThresholdMinutes,minimizeToTray,startMinimized,autoStartTracking,const DeepCollectionEquality().hash(_excludedApps),dbPath,pomodoro,appTimeout);

@override
String toString() {
  return 'AppSettings(pollIntervalMs: $pollIntervalMs, idleThresholdMinutes: $idleThresholdMinutes, minimizeToTray: $minimizeToTray, startMinimized: $startMinimized, autoStartTracking: $autoStartTracking, excludedApps: $excludedApps, dbPath: $dbPath, pomodoro: $pomodoro, appTimeout: $appTimeout)';
}


}

/// @nodoc
abstract mixin class _$AppSettingsCopyWith<$Res> implements $AppSettingsCopyWith<$Res> {
  factory _$AppSettingsCopyWith(_AppSettings value, $Res Function(_AppSettings) _then) = __$AppSettingsCopyWithImpl;
@override @useResult
$Res call({
 int pollIntervalMs, int idleThresholdMinutes, bool minimizeToTray, bool startMinimized, bool autoStartTracking, List<String> excludedApps, String dbPath, PomodoroSettings pomodoro, AppTimeoutSettings appTimeout
});


@override $PomodoroSettingsCopyWith<$Res> get pomodoro;@override $AppTimeoutSettingsCopyWith<$Res> get appTimeout;

}
/// @nodoc
class __$AppSettingsCopyWithImpl<$Res>
    implements _$AppSettingsCopyWith<$Res> {
  __$AppSettingsCopyWithImpl(this._self, this._then);

  final _AppSettings _self;
  final $Res Function(_AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? pollIntervalMs = null,Object? idleThresholdMinutes = null,Object? minimizeToTray = null,Object? startMinimized = null,Object? autoStartTracking = null,Object? excludedApps = null,Object? dbPath = null,Object? pomodoro = null,Object? appTimeout = null,}) {
  return _then(_AppSettings(
pollIntervalMs: null == pollIntervalMs ? _self.pollIntervalMs : pollIntervalMs // ignore: cast_nullable_to_non_nullable
as int,idleThresholdMinutes: null == idleThresholdMinutes ? _self.idleThresholdMinutes : idleThresholdMinutes // ignore: cast_nullable_to_non_nullable
as int,minimizeToTray: null == minimizeToTray ? _self.minimizeToTray : minimizeToTray // ignore: cast_nullable_to_non_nullable
as bool,startMinimized: null == startMinimized ? _self.startMinimized : startMinimized // ignore: cast_nullable_to_non_nullable
as bool,autoStartTracking: null == autoStartTracking ? _self.autoStartTracking : autoStartTracking // ignore: cast_nullable_to_non_nullable
as bool,excludedApps: null == excludedApps ? _self._excludedApps : excludedApps // ignore: cast_nullable_to_non_nullable
as List<String>,dbPath: null == dbPath ? _self.dbPath : dbPath // ignore: cast_nullable_to_non_nullable
as String,pomodoro: null == pomodoro ? _self.pomodoro : pomodoro // ignore: cast_nullable_to_non_nullable
as PomodoroSettings,appTimeout: null == appTimeout ? _self.appTimeout : appTimeout // ignore: cast_nullable_to_non_nullable
as AppTimeoutSettings,
  ));
}

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PomodoroSettingsCopyWith<$Res> get pomodoro {

  return $PomodoroSettingsCopyWith<$Res>(_self.pomodoro, (value) {
    return _then(_self.copyWith(pomodoro: value));
  });
}/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AppTimeoutSettingsCopyWith<$Res> get appTimeout {

  return $AppTimeoutSettingsCopyWith<$Res>(_self.appTimeout, (value) {
    return _then(_self.copyWith(appTimeout: value));
  });
}
}

// dart format on
