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
mixin _$AppSettings {

 int get pollIntervalMs; int get idleThresholdMinutes; bool get minimizeToTray; bool get startMinimized; bool get autoStartTracking; List<String> get excludedApps; String get dbPath;
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppSettingsCopyWith<AppSettings> get copyWith => _$AppSettingsCopyWithImpl<AppSettings>(this as AppSettings, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppSettings&&(identical(other.pollIntervalMs, pollIntervalMs) || other.pollIntervalMs == pollIntervalMs)&&(identical(other.idleThresholdMinutes, idleThresholdMinutes) || other.idleThresholdMinutes == idleThresholdMinutes)&&(identical(other.minimizeToTray, minimizeToTray) || other.minimizeToTray == minimizeToTray)&&(identical(other.startMinimized, startMinimized) || other.startMinimized == startMinimized)&&(identical(other.autoStartTracking, autoStartTracking) || other.autoStartTracking == autoStartTracking)&&const DeepCollectionEquality().equals(other.excludedApps, excludedApps)&&(identical(other.dbPath, dbPath) || other.dbPath == dbPath));
}


@override
int get hashCode => Object.hash(runtimeType,pollIntervalMs,idleThresholdMinutes,minimizeToTray,startMinimized,autoStartTracking,const DeepCollectionEquality().hash(excludedApps),dbPath);

@override
String toString() {
  return 'AppSettings(pollIntervalMs: $pollIntervalMs, idleThresholdMinutes: $idleThresholdMinutes, minimizeToTray: $minimizeToTray, startMinimized: $startMinimized, autoStartTracking: $autoStartTracking, excludedApps: $excludedApps, dbPath: $dbPath)';
}


}

/// @nodoc
abstract mixin class $AppSettingsCopyWith<$Res>  {
  factory $AppSettingsCopyWith(AppSettings value, $Res Function(AppSettings) _then) = _$AppSettingsCopyWithImpl;
@useResult
$Res call({
 int pollIntervalMs, int idleThresholdMinutes, bool minimizeToTray, bool startMinimized, bool autoStartTracking, List<String> excludedApps, String dbPath
});




}
/// @nodoc
class _$AppSettingsCopyWithImpl<$Res>
    implements $AppSettingsCopyWith<$Res> {
  _$AppSettingsCopyWithImpl(this._self, this._then);

  final AppSettings _self;
  final $Res Function(AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? pollIntervalMs = null,Object? idleThresholdMinutes = null,Object? minimizeToTray = null,Object? startMinimized = null,Object? autoStartTracking = null,Object? excludedApps = null,Object? dbPath = null,}) {
  return _then(_self.copyWith(
pollIntervalMs: null == pollIntervalMs ? _self.pollIntervalMs : pollIntervalMs // ignore: cast_nullable_to_non_nullable
as int,idleThresholdMinutes: null == idleThresholdMinutes ? _self.idleThresholdMinutes : idleThresholdMinutes // ignore: cast_nullable_to_non_nullable
as int,minimizeToTray: null == minimizeToTray ? _self.minimizeToTray : minimizeToTray // ignore: cast_nullable_to_non_nullable
as bool,startMinimized: null == startMinimized ? _self.startMinimized : startMinimized // ignore: cast_nullable_to_non_nullable
as bool,autoStartTracking: null == autoStartTracking ? _self.autoStartTracking : autoStartTracking // ignore: cast_nullable_to_non_nullable
as bool,excludedApps: null == excludedApps ? _self.excludedApps : excludedApps // ignore: cast_nullable_to_non_nullable
as List<String>,dbPath: null == dbPath ? _self.dbPath : dbPath // ignore: cast_nullable_to_non_nullable
as String,
  ));
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int pollIntervalMs,  int idleThresholdMinutes,  bool minimizeToTray,  bool startMinimized,  bool autoStartTracking,  List<String> excludedApps,  String dbPath)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.pollIntervalMs,_that.idleThresholdMinutes,_that.minimizeToTray,_that.startMinimized,_that.autoStartTracking,_that.excludedApps,_that.dbPath);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int pollIntervalMs,  int idleThresholdMinutes,  bool minimizeToTray,  bool startMinimized,  bool autoStartTracking,  List<String> excludedApps,  String dbPath)  $default,) {final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that.pollIntervalMs,_that.idleThresholdMinutes,_that.minimizeToTray,_that.startMinimized,_that.autoStartTracking,_that.excludedApps,_that.dbPath);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int pollIntervalMs,  int idleThresholdMinutes,  bool minimizeToTray,  bool startMinimized,  bool autoStartTracking,  List<String> excludedApps,  String dbPath)?  $default,) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.pollIntervalMs,_that.idleThresholdMinutes,_that.minimizeToTray,_that.startMinimized,_that.autoStartTracking,_that.excludedApps,_that.dbPath);case _:
  return null;

}
}

}

/// @nodoc


class _AppSettings extends AppSettings {
  const _AppSettings({required this.pollIntervalMs, required this.idleThresholdMinutes, required this.minimizeToTray, required this.startMinimized, required this.autoStartTracking, required final  List<String> excludedApps, required this.dbPath}): _excludedApps = excludedApps,super._();
  

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

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppSettingsCopyWith<_AppSettings> get copyWith => __$AppSettingsCopyWithImpl<_AppSettings>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppSettings&&(identical(other.pollIntervalMs, pollIntervalMs) || other.pollIntervalMs == pollIntervalMs)&&(identical(other.idleThresholdMinutes, idleThresholdMinutes) || other.idleThresholdMinutes == idleThresholdMinutes)&&(identical(other.minimizeToTray, minimizeToTray) || other.minimizeToTray == minimizeToTray)&&(identical(other.startMinimized, startMinimized) || other.startMinimized == startMinimized)&&(identical(other.autoStartTracking, autoStartTracking) || other.autoStartTracking == autoStartTracking)&&const DeepCollectionEquality().equals(other._excludedApps, _excludedApps)&&(identical(other.dbPath, dbPath) || other.dbPath == dbPath));
}


@override
int get hashCode => Object.hash(runtimeType,pollIntervalMs,idleThresholdMinutes,minimizeToTray,startMinimized,autoStartTracking,const DeepCollectionEquality().hash(_excludedApps),dbPath);

@override
String toString() {
  return 'AppSettings(pollIntervalMs: $pollIntervalMs, idleThresholdMinutes: $idleThresholdMinutes, minimizeToTray: $minimizeToTray, startMinimized: $startMinimized, autoStartTracking: $autoStartTracking, excludedApps: $excludedApps, dbPath: $dbPath)';
}


}

/// @nodoc
abstract mixin class _$AppSettingsCopyWith<$Res> implements $AppSettingsCopyWith<$Res> {
  factory _$AppSettingsCopyWith(_AppSettings value, $Res Function(_AppSettings) _then) = __$AppSettingsCopyWithImpl;
@override @useResult
$Res call({
 int pollIntervalMs, int idleThresholdMinutes, bool minimizeToTray, bool startMinimized, bool autoStartTracking, List<String> excludedApps, String dbPath
});




}
/// @nodoc
class __$AppSettingsCopyWithImpl<$Res>
    implements _$AppSettingsCopyWith<$Res> {
  __$AppSettingsCopyWithImpl(this._self, this._then);

  final _AppSettings _self;
  final $Res Function(_AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? pollIntervalMs = null,Object? idleThresholdMinutes = null,Object? minimizeToTray = null,Object? startMinimized = null,Object? autoStartTracking = null,Object? excludedApps = null,Object? dbPath = null,}) {
  return _then(_AppSettings(
pollIntervalMs: null == pollIntervalMs ? _self.pollIntervalMs : pollIntervalMs // ignore: cast_nullable_to_non_nullable
as int,idleThresholdMinutes: null == idleThresholdMinutes ? _self.idleThresholdMinutes : idleThresholdMinutes // ignore: cast_nullable_to_non_nullable
as int,minimizeToTray: null == minimizeToTray ? _self.minimizeToTray : minimizeToTray // ignore: cast_nullable_to_non_nullable
as bool,startMinimized: null == startMinimized ? _self.startMinimized : startMinimized // ignore: cast_nullable_to_non_nullable
as bool,autoStartTracking: null == autoStartTracking ? _self.autoStartTracking : autoStartTracking // ignore: cast_nullable_to_non_nullable
as bool,excludedApps: null == excludedApps ? _self._excludedApps : excludedApps // ignore: cast_nullable_to_non_nullable
as List<String>,dbPath: null == dbPath ? _self.dbPath : dbPath // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
