// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dashboard_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$DashboardState {

 List<AppUsageItem> get apps; List<AttributionTotalDto> get appAttribution; List<AttributionTotalDto> get windows; List<AttributionTotalDto> get pages; List<LocalHourBucketDto> get hours; int get totalActiveSeconds; int get totalIdleSeconds; int get pausedSeconds; int get privacyExcludedSeconds; int get systemGapSeconds; int get unknownSeconds; int get accountedSeconds; SnapshotIntegrityDto get integrity; String get requestedStartUtc; String get requestedEndUtc; String get effectiveStartUtc; String get effectiveEndUtc; String get observedThroughUtc; bool get databaseDegraded;
/// Create a copy of DashboardState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DashboardStateCopyWith<DashboardState> get copyWith => _$DashboardStateCopyWithImpl<DashboardState>(this as DashboardState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DashboardState&&const DeepCollectionEquality().equals(other.apps, apps)&&const DeepCollectionEquality().equals(other.appAttribution, appAttribution)&&const DeepCollectionEquality().equals(other.windows, windows)&&const DeepCollectionEquality().equals(other.pages, pages)&&const DeepCollectionEquality().equals(other.hours, hours)&&(identical(other.totalActiveSeconds, totalActiveSeconds) || other.totalActiveSeconds == totalActiveSeconds)&&(identical(other.totalIdleSeconds, totalIdleSeconds) || other.totalIdleSeconds == totalIdleSeconds)&&(identical(other.pausedSeconds, pausedSeconds) || other.pausedSeconds == pausedSeconds)&&(identical(other.privacyExcludedSeconds, privacyExcludedSeconds) || other.privacyExcludedSeconds == privacyExcludedSeconds)&&(identical(other.systemGapSeconds, systemGapSeconds) || other.systemGapSeconds == systemGapSeconds)&&(identical(other.unknownSeconds, unknownSeconds) || other.unknownSeconds == unknownSeconds)&&(identical(other.accountedSeconds, accountedSeconds) || other.accountedSeconds == accountedSeconds)&&(identical(other.integrity, integrity) || other.integrity == integrity)&&(identical(other.requestedStartUtc, requestedStartUtc) || other.requestedStartUtc == requestedStartUtc)&&(identical(other.requestedEndUtc, requestedEndUtc) || other.requestedEndUtc == requestedEndUtc)&&(identical(other.effectiveStartUtc, effectiveStartUtc) || other.effectiveStartUtc == effectiveStartUtc)&&(identical(other.effectiveEndUtc, effectiveEndUtc) || other.effectiveEndUtc == effectiveEndUtc)&&(identical(other.observedThroughUtc, observedThroughUtc) || other.observedThroughUtc == observedThroughUtc)&&(identical(other.databaseDegraded, databaseDegraded) || other.databaseDegraded == databaseDegraded));
}


@override
int get hashCode => Object.hashAll([runtimeType,const DeepCollectionEquality().hash(apps),const DeepCollectionEquality().hash(appAttribution),const DeepCollectionEquality().hash(windows),const DeepCollectionEquality().hash(pages),const DeepCollectionEquality().hash(hours),totalActiveSeconds,totalIdleSeconds,pausedSeconds,privacyExcludedSeconds,systemGapSeconds,unknownSeconds,accountedSeconds,integrity,requestedStartUtc,requestedEndUtc,effectiveStartUtc,effectiveEndUtc,observedThroughUtc,databaseDegraded]);

@override
String toString() {
  return 'DashboardState(apps: $apps, appAttribution: $appAttribution, windows: $windows, pages: $pages, hours: $hours, totalActiveSeconds: $totalActiveSeconds, totalIdleSeconds: $totalIdleSeconds, pausedSeconds: $pausedSeconds, privacyExcludedSeconds: $privacyExcludedSeconds, systemGapSeconds: $systemGapSeconds, unknownSeconds: $unknownSeconds, accountedSeconds: $accountedSeconds, integrity: $integrity, requestedStartUtc: $requestedStartUtc, requestedEndUtc: $requestedEndUtc, effectiveStartUtc: $effectiveStartUtc, effectiveEndUtc: $effectiveEndUtc, observedThroughUtc: $observedThroughUtc, databaseDegraded: $databaseDegraded)';
}


}

/// @nodoc
abstract mixin class $DashboardStateCopyWith<$Res>  {
  factory $DashboardStateCopyWith(DashboardState value, $Res Function(DashboardState) _then) = _$DashboardStateCopyWithImpl;
@useResult
$Res call({
 List<AppUsageItem> apps, List<AttributionTotalDto> appAttribution, List<AttributionTotalDto> windows, List<AttributionTotalDto> pages, List<LocalHourBucketDto> hours, int totalActiveSeconds, int totalIdleSeconds, int pausedSeconds, int privacyExcludedSeconds, int systemGapSeconds, int unknownSeconds, int accountedSeconds, SnapshotIntegrityDto integrity, String requestedStartUtc, String requestedEndUtc, String effectiveStartUtc, String effectiveEndUtc, String observedThroughUtc, bool databaseDegraded
});




}
/// @nodoc
class _$DashboardStateCopyWithImpl<$Res>
    implements $DashboardStateCopyWith<$Res> {
  _$DashboardStateCopyWithImpl(this._self, this._then);

  final DashboardState _self;
  final $Res Function(DashboardState) _then;

/// Create a copy of DashboardState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? apps = null,Object? appAttribution = null,Object? windows = null,Object? pages = null,Object? hours = null,Object? totalActiveSeconds = null,Object? totalIdleSeconds = null,Object? pausedSeconds = null,Object? privacyExcludedSeconds = null,Object? systemGapSeconds = null,Object? unknownSeconds = null,Object? accountedSeconds = null,Object? integrity = null,Object? requestedStartUtc = null,Object? requestedEndUtc = null,Object? effectiveStartUtc = null,Object? effectiveEndUtc = null,Object? observedThroughUtc = null,Object? databaseDegraded = null,}) {
  return _then(_self.copyWith(
apps: null == apps ? _self.apps : apps // ignore: cast_nullable_to_non_nullable
as List<AppUsageItem>,appAttribution: null == appAttribution ? _self.appAttribution : appAttribution // ignore: cast_nullable_to_non_nullable
as List<AttributionTotalDto>,windows: null == windows ? _self.windows : windows // ignore: cast_nullable_to_non_nullable
as List<AttributionTotalDto>,pages: null == pages ? _self.pages : pages // ignore: cast_nullable_to_non_nullable
as List<AttributionTotalDto>,hours: null == hours ? _self.hours : hours // ignore: cast_nullable_to_non_nullable
as List<LocalHourBucketDto>,totalActiveSeconds: null == totalActiveSeconds ? _self.totalActiveSeconds : totalActiveSeconds // ignore: cast_nullable_to_non_nullable
as int,totalIdleSeconds: null == totalIdleSeconds ? _self.totalIdleSeconds : totalIdleSeconds // ignore: cast_nullable_to_non_nullable
as int,pausedSeconds: null == pausedSeconds ? _self.pausedSeconds : pausedSeconds // ignore: cast_nullable_to_non_nullable
as int,privacyExcludedSeconds: null == privacyExcludedSeconds ? _self.privacyExcludedSeconds : privacyExcludedSeconds // ignore: cast_nullable_to_non_nullable
as int,systemGapSeconds: null == systemGapSeconds ? _self.systemGapSeconds : systemGapSeconds // ignore: cast_nullable_to_non_nullable
as int,unknownSeconds: null == unknownSeconds ? _self.unknownSeconds : unknownSeconds // ignore: cast_nullable_to_non_nullable
as int,accountedSeconds: null == accountedSeconds ? _self.accountedSeconds : accountedSeconds // ignore: cast_nullable_to_non_nullable
as int,integrity: null == integrity ? _self.integrity : integrity // ignore: cast_nullable_to_non_nullable
as SnapshotIntegrityDto,requestedStartUtc: null == requestedStartUtc ? _self.requestedStartUtc : requestedStartUtc // ignore: cast_nullable_to_non_nullable
as String,requestedEndUtc: null == requestedEndUtc ? _self.requestedEndUtc : requestedEndUtc // ignore: cast_nullable_to_non_nullable
as String,effectiveStartUtc: null == effectiveStartUtc ? _self.effectiveStartUtc : effectiveStartUtc // ignore: cast_nullable_to_non_nullable
as String,effectiveEndUtc: null == effectiveEndUtc ? _self.effectiveEndUtc : effectiveEndUtc // ignore: cast_nullable_to_non_nullable
as String,observedThroughUtc: null == observedThroughUtc ? _self.observedThroughUtc : observedThroughUtc // ignore: cast_nullable_to_non_nullable
as String,databaseDegraded: null == databaseDegraded ? _self.databaseDegraded : databaseDegraded // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [DashboardState].
extension DashboardStatePatterns on DashboardState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DashboardState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DashboardState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DashboardState value)  $default,){
final _that = this;
switch (_that) {
case _DashboardState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DashboardState value)?  $default,){
final _that = this;
switch (_that) {
case _DashboardState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<AppUsageItem> apps,  List<AttributionTotalDto> appAttribution,  List<AttributionTotalDto> windows,  List<AttributionTotalDto> pages,  List<LocalHourBucketDto> hours,  int totalActiveSeconds,  int totalIdleSeconds,  int pausedSeconds,  int privacyExcludedSeconds,  int systemGapSeconds,  int unknownSeconds,  int accountedSeconds,  SnapshotIntegrityDto integrity,  String requestedStartUtc,  String requestedEndUtc,  String effectiveStartUtc,  String effectiveEndUtc,  String observedThroughUtc,  bool databaseDegraded)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DashboardState() when $default != null:
return $default(_that.apps,_that.appAttribution,_that.windows,_that.pages,_that.hours,_that.totalActiveSeconds,_that.totalIdleSeconds,_that.pausedSeconds,_that.privacyExcludedSeconds,_that.systemGapSeconds,_that.unknownSeconds,_that.accountedSeconds,_that.integrity,_that.requestedStartUtc,_that.requestedEndUtc,_that.effectiveStartUtc,_that.effectiveEndUtc,_that.observedThroughUtc,_that.databaseDegraded);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<AppUsageItem> apps,  List<AttributionTotalDto> appAttribution,  List<AttributionTotalDto> windows,  List<AttributionTotalDto> pages,  List<LocalHourBucketDto> hours,  int totalActiveSeconds,  int totalIdleSeconds,  int pausedSeconds,  int privacyExcludedSeconds,  int systemGapSeconds,  int unknownSeconds,  int accountedSeconds,  SnapshotIntegrityDto integrity,  String requestedStartUtc,  String requestedEndUtc,  String effectiveStartUtc,  String effectiveEndUtc,  String observedThroughUtc,  bool databaseDegraded)  $default,) {final _that = this;
switch (_that) {
case _DashboardState():
return $default(_that.apps,_that.appAttribution,_that.windows,_that.pages,_that.hours,_that.totalActiveSeconds,_that.totalIdleSeconds,_that.pausedSeconds,_that.privacyExcludedSeconds,_that.systemGapSeconds,_that.unknownSeconds,_that.accountedSeconds,_that.integrity,_that.requestedStartUtc,_that.requestedEndUtc,_that.effectiveStartUtc,_that.effectiveEndUtc,_that.observedThroughUtc,_that.databaseDegraded);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<AppUsageItem> apps,  List<AttributionTotalDto> appAttribution,  List<AttributionTotalDto> windows,  List<AttributionTotalDto> pages,  List<LocalHourBucketDto> hours,  int totalActiveSeconds,  int totalIdleSeconds,  int pausedSeconds,  int privacyExcludedSeconds,  int systemGapSeconds,  int unknownSeconds,  int accountedSeconds,  SnapshotIntegrityDto integrity,  String requestedStartUtc,  String requestedEndUtc,  String effectiveStartUtc,  String effectiveEndUtc,  String observedThroughUtc,  bool databaseDegraded)?  $default,) {final _that = this;
switch (_that) {
case _DashboardState() when $default != null:
return $default(_that.apps,_that.appAttribution,_that.windows,_that.pages,_that.hours,_that.totalActiveSeconds,_that.totalIdleSeconds,_that.pausedSeconds,_that.privacyExcludedSeconds,_that.systemGapSeconds,_that.unknownSeconds,_that.accountedSeconds,_that.integrity,_that.requestedStartUtc,_that.requestedEndUtc,_that.effectiveStartUtc,_that.effectiveEndUtc,_that.observedThroughUtc,_that.databaseDegraded);case _:
  return null;

}
}

}

/// @nodoc


class _DashboardState extends DashboardState {
  const _DashboardState({required final  List<AppUsageItem> apps, required final  List<AttributionTotalDto> appAttribution, required final  List<AttributionTotalDto> windows, required final  List<AttributionTotalDto> pages, required final  List<LocalHourBucketDto> hours, required this.totalActiveSeconds, required this.totalIdleSeconds, required this.pausedSeconds, required this.privacyExcludedSeconds, required this.systemGapSeconds, required this.unknownSeconds, required this.accountedSeconds, required this.integrity, required this.requestedStartUtc, required this.requestedEndUtc, required this.effectiveStartUtc, required this.effectiveEndUtc, required this.observedThroughUtc, this.databaseDegraded = false}): _apps = apps,_appAttribution = appAttribution,_windows = windows,_pages = pages,_hours = hours,super._();
  

 final  List<AppUsageItem> _apps;
@override List<AppUsageItem> get apps {
  if (_apps is EqualUnmodifiableListView) return _apps;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_apps);
}

 final  List<AttributionTotalDto> _appAttribution;
@override List<AttributionTotalDto> get appAttribution {
  if (_appAttribution is EqualUnmodifiableListView) return _appAttribution;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_appAttribution);
}

 final  List<AttributionTotalDto> _windows;
@override List<AttributionTotalDto> get windows {
  if (_windows is EqualUnmodifiableListView) return _windows;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_windows);
}

 final  List<AttributionTotalDto> _pages;
@override List<AttributionTotalDto> get pages {
  if (_pages is EqualUnmodifiableListView) return _pages;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_pages);
}

 final  List<LocalHourBucketDto> _hours;
@override List<LocalHourBucketDto> get hours {
  if (_hours is EqualUnmodifiableListView) return _hours;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_hours);
}

@override final  int totalActiveSeconds;
@override final  int totalIdleSeconds;
@override final  int pausedSeconds;
@override final  int privacyExcludedSeconds;
@override final  int systemGapSeconds;
@override final  int unknownSeconds;
@override final  int accountedSeconds;
@override final  SnapshotIntegrityDto integrity;
@override final  String requestedStartUtc;
@override final  String requestedEndUtc;
@override final  String effectiveStartUtc;
@override final  String effectiveEndUtc;
@override final  String observedThroughUtc;
@override@JsonKey() final  bool databaseDegraded;

/// Create a copy of DashboardState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DashboardStateCopyWith<_DashboardState> get copyWith => __$DashboardStateCopyWithImpl<_DashboardState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _DashboardState&&const DeepCollectionEquality().equals(other._apps, _apps)&&const DeepCollectionEquality().equals(other._appAttribution, _appAttribution)&&const DeepCollectionEquality().equals(other._windows, _windows)&&const DeepCollectionEquality().equals(other._pages, _pages)&&const DeepCollectionEquality().equals(other._hours, _hours)&&(identical(other.totalActiveSeconds, totalActiveSeconds) || other.totalActiveSeconds == totalActiveSeconds)&&(identical(other.totalIdleSeconds, totalIdleSeconds) || other.totalIdleSeconds == totalIdleSeconds)&&(identical(other.pausedSeconds, pausedSeconds) || other.pausedSeconds == pausedSeconds)&&(identical(other.privacyExcludedSeconds, privacyExcludedSeconds) || other.privacyExcludedSeconds == privacyExcludedSeconds)&&(identical(other.systemGapSeconds, systemGapSeconds) || other.systemGapSeconds == systemGapSeconds)&&(identical(other.unknownSeconds, unknownSeconds) || other.unknownSeconds == unknownSeconds)&&(identical(other.accountedSeconds, accountedSeconds) || other.accountedSeconds == accountedSeconds)&&(identical(other.integrity, integrity) || other.integrity == integrity)&&(identical(other.requestedStartUtc, requestedStartUtc) || other.requestedStartUtc == requestedStartUtc)&&(identical(other.requestedEndUtc, requestedEndUtc) || other.requestedEndUtc == requestedEndUtc)&&(identical(other.effectiveStartUtc, effectiveStartUtc) || other.effectiveStartUtc == effectiveStartUtc)&&(identical(other.effectiveEndUtc, effectiveEndUtc) || other.effectiveEndUtc == effectiveEndUtc)&&(identical(other.observedThroughUtc, observedThroughUtc) || other.observedThroughUtc == observedThroughUtc)&&(identical(other.databaseDegraded, databaseDegraded) || other.databaseDegraded == databaseDegraded));
}


@override
int get hashCode => Object.hashAll([runtimeType,const DeepCollectionEquality().hash(_apps),const DeepCollectionEquality().hash(_appAttribution),const DeepCollectionEquality().hash(_windows),const DeepCollectionEquality().hash(_pages),const DeepCollectionEquality().hash(_hours),totalActiveSeconds,totalIdleSeconds,pausedSeconds,privacyExcludedSeconds,systemGapSeconds,unknownSeconds,accountedSeconds,integrity,requestedStartUtc,requestedEndUtc,effectiveStartUtc,effectiveEndUtc,observedThroughUtc,databaseDegraded]);

@override
String toString() {
  return 'DashboardState(apps: $apps, appAttribution: $appAttribution, windows: $windows, pages: $pages, hours: $hours, totalActiveSeconds: $totalActiveSeconds, totalIdleSeconds: $totalIdleSeconds, pausedSeconds: $pausedSeconds, privacyExcludedSeconds: $privacyExcludedSeconds, systemGapSeconds: $systemGapSeconds, unknownSeconds: $unknownSeconds, accountedSeconds: $accountedSeconds, integrity: $integrity, requestedStartUtc: $requestedStartUtc, requestedEndUtc: $requestedEndUtc, effectiveStartUtc: $effectiveStartUtc, effectiveEndUtc: $effectiveEndUtc, observedThroughUtc: $observedThroughUtc, databaseDegraded: $databaseDegraded)';
}


}

/// @nodoc
abstract mixin class _$DashboardStateCopyWith<$Res> implements $DashboardStateCopyWith<$Res> {
  factory _$DashboardStateCopyWith(_DashboardState value, $Res Function(_DashboardState) _then) = __$DashboardStateCopyWithImpl;
@override @useResult
$Res call({
 List<AppUsageItem> apps, List<AttributionTotalDto> appAttribution, List<AttributionTotalDto> windows, List<AttributionTotalDto> pages, List<LocalHourBucketDto> hours, int totalActiveSeconds, int totalIdleSeconds, int pausedSeconds, int privacyExcludedSeconds, int systemGapSeconds, int unknownSeconds, int accountedSeconds, SnapshotIntegrityDto integrity, String requestedStartUtc, String requestedEndUtc, String effectiveStartUtc, String effectiveEndUtc, String observedThroughUtc, bool databaseDegraded
});




}
/// @nodoc
class __$DashboardStateCopyWithImpl<$Res>
    implements _$DashboardStateCopyWith<$Res> {
  __$DashboardStateCopyWithImpl(this._self, this._then);

  final _DashboardState _self;
  final $Res Function(_DashboardState) _then;

/// Create a copy of DashboardState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? apps = null,Object? appAttribution = null,Object? windows = null,Object? pages = null,Object? hours = null,Object? totalActiveSeconds = null,Object? totalIdleSeconds = null,Object? pausedSeconds = null,Object? privacyExcludedSeconds = null,Object? systemGapSeconds = null,Object? unknownSeconds = null,Object? accountedSeconds = null,Object? integrity = null,Object? requestedStartUtc = null,Object? requestedEndUtc = null,Object? effectiveStartUtc = null,Object? effectiveEndUtc = null,Object? observedThroughUtc = null,Object? databaseDegraded = null,}) {
  return _then(_DashboardState(
apps: null == apps ? _self._apps : apps // ignore: cast_nullable_to_non_nullable
as List<AppUsageItem>,appAttribution: null == appAttribution ? _self._appAttribution : appAttribution // ignore: cast_nullable_to_non_nullable
as List<AttributionTotalDto>,windows: null == windows ? _self._windows : windows // ignore: cast_nullable_to_non_nullable
as List<AttributionTotalDto>,pages: null == pages ? _self._pages : pages // ignore: cast_nullable_to_non_nullable
as List<AttributionTotalDto>,hours: null == hours ? _self._hours : hours // ignore: cast_nullable_to_non_nullable
as List<LocalHourBucketDto>,totalActiveSeconds: null == totalActiveSeconds ? _self.totalActiveSeconds : totalActiveSeconds // ignore: cast_nullable_to_non_nullable
as int,totalIdleSeconds: null == totalIdleSeconds ? _self.totalIdleSeconds : totalIdleSeconds // ignore: cast_nullable_to_non_nullable
as int,pausedSeconds: null == pausedSeconds ? _self.pausedSeconds : pausedSeconds // ignore: cast_nullable_to_non_nullable
as int,privacyExcludedSeconds: null == privacyExcludedSeconds ? _self.privacyExcludedSeconds : privacyExcludedSeconds // ignore: cast_nullable_to_non_nullable
as int,systemGapSeconds: null == systemGapSeconds ? _self.systemGapSeconds : systemGapSeconds // ignore: cast_nullable_to_non_nullable
as int,unknownSeconds: null == unknownSeconds ? _self.unknownSeconds : unknownSeconds // ignore: cast_nullable_to_non_nullable
as int,accountedSeconds: null == accountedSeconds ? _self.accountedSeconds : accountedSeconds // ignore: cast_nullable_to_non_nullable
as int,integrity: null == integrity ? _self.integrity : integrity // ignore: cast_nullable_to_non_nullable
as SnapshotIntegrityDto,requestedStartUtc: null == requestedStartUtc ? _self.requestedStartUtc : requestedStartUtc // ignore: cast_nullable_to_non_nullable
as String,requestedEndUtc: null == requestedEndUtc ? _self.requestedEndUtc : requestedEndUtc // ignore: cast_nullable_to_non_nullable
as String,effectiveStartUtc: null == effectiveStartUtc ? _self.effectiveStartUtc : effectiveStartUtc // ignore: cast_nullable_to_non_nullable
as String,effectiveEndUtc: null == effectiveEndUtc ? _self.effectiveEndUtc : effectiveEndUtc // ignore: cast_nullable_to_non_nullable
as String,observedThroughUtc: null == observedThroughUtc ? _self.observedThroughUtc : observedThroughUtc // ignore: cast_nullable_to_non_nullable
as String,databaseDegraded: null == databaseDegraded ? _self.databaseDegraded : databaseDegraded // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$AppUsageItem {

 String get appName; int get activeSeconds; int get idleSeconds; String? get exePath;
/// Create a copy of AppUsageItem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppUsageItemCopyWith<AppUsageItem> get copyWith => _$AppUsageItemCopyWithImpl<AppUsageItem>(this as AppUsageItem, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppUsageItem&&(identical(other.appName, appName) || other.appName == appName)&&(identical(other.activeSeconds, activeSeconds) || other.activeSeconds == activeSeconds)&&(identical(other.idleSeconds, idleSeconds) || other.idleSeconds == idleSeconds)&&(identical(other.exePath, exePath) || other.exePath == exePath));
}


@override
int get hashCode => Object.hash(runtimeType,appName,activeSeconds,idleSeconds,exePath);

@override
String toString() {
  return 'AppUsageItem(appName: $appName, activeSeconds: $activeSeconds, idleSeconds: $idleSeconds, exePath: $exePath)';
}


}

/// @nodoc
abstract mixin class $AppUsageItemCopyWith<$Res>  {
  factory $AppUsageItemCopyWith(AppUsageItem value, $Res Function(AppUsageItem) _then) = _$AppUsageItemCopyWithImpl;
@useResult
$Res call({
 String appName, int activeSeconds, int idleSeconds, String? exePath
});




}
/// @nodoc
class _$AppUsageItemCopyWithImpl<$Res>
    implements $AppUsageItemCopyWith<$Res> {
  _$AppUsageItemCopyWithImpl(this._self, this._then);

  final AppUsageItem _self;
  final $Res Function(AppUsageItem) _then;

/// Create a copy of AppUsageItem
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? appName = null,Object? activeSeconds = null,Object? idleSeconds = null,Object? exePath = freezed,}) {
  return _then(_self.copyWith(
appName: null == appName ? _self.appName : appName // ignore: cast_nullable_to_non_nullable
as String,activeSeconds: null == activeSeconds ? _self.activeSeconds : activeSeconds // ignore: cast_nullable_to_non_nullable
as int,idleSeconds: null == idleSeconds ? _self.idleSeconds : idleSeconds // ignore: cast_nullable_to_non_nullable
as int,exePath: freezed == exePath ? _self.exePath : exePath // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [AppUsageItem].
extension AppUsageItemPatterns on AppUsageItem {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppUsageItem value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppUsageItem() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppUsageItem value)  $default,){
final _that = this;
switch (_that) {
case _AppUsageItem():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppUsageItem value)?  $default,){
final _that = this;
switch (_that) {
case _AppUsageItem() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String appName,  int activeSeconds,  int idleSeconds,  String? exePath)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppUsageItem() when $default != null:
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds,_that.exePath);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String appName,  int activeSeconds,  int idleSeconds,  String? exePath)  $default,) {final _that = this;
switch (_that) {
case _AppUsageItem():
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds,_that.exePath);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String appName,  int activeSeconds,  int idleSeconds,  String? exePath)?  $default,) {final _that = this;
switch (_that) {
case _AppUsageItem() when $default != null:
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds,_that.exePath);case _:
  return null;

}
}

}

/// @nodoc


class _AppUsageItem extends AppUsageItem {
  const _AppUsageItem({required this.appName, required this.activeSeconds, required this.idleSeconds, this.exePath}): super._();
  

@override final  String appName;
@override final  int activeSeconds;
@override final  int idleSeconds;
@override final  String? exePath;

/// Create a copy of AppUsageItem
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppUsageItemCopyWith<_AppUsageItem> get copyWith => __$AppUsageItemCopyWithImpl<_AppUsageItem>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppUsageItem&&(identical(other.appName, appName) || other.appName == appName)&&(identical(other.activeSeconds, activeSeconds) || other.activeSeconds == activeSeconds)&&(identical(other.idleSeconds, idleSeconds) || other.idleSeconds == idleSeconds)&&(identical(other.exePath, exePath) || other.exePath == exePath));
}


@override
int get hashCode => Object.hash(runtimeType,appName,activeSeconds,idleSeconds,exePath);

@override
String toString() {
  return 'AppUsageItem(appName: $appName, activeSeconds: $activeSeconds, idleSeconds: $idleSeconds, exePath: $exePath)';
}


}

/// @nodoc
abstract mixin class _$AppUsageItemCopyWith<$Res> implements $AppUsageItemCopyWith<$Res> {
  factory _$AppUsageItemCopyWith(_AppUsageItem value, $Res Function(_AppUsageItem) _then) = __$AppUsageItemCopyWithImpl;
@override @useResult
$Res call({
 String appName, int activeSeconds, int idleSeconds, String? exePath
});




}
/// @nodoc
class __$AppUsageItemCopyWithImpl<$Res>
    implements _$AppUsageItemCopyWith<$Res> {
  __$AppUsageItemCopyWithImpl(this._self, this._then);

  final _AppUsageItem _self;
  final $Res Function(_AppUsageItem) _then;

/// Create a copy of AppUsageItem
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? appName = null,Object? activeSeconds = null,Object? idleSeconds = null,Object? exePath = freezed,}) {
  return _then(_AppUsageItem(
appName: null == appName ? _self.appName : appName // ignore: cast_nullable_to_non_nullable
as String,activeSeconds: null == activeSeconds ? _self.activeSeconds : activeSeconds // ignore: cast_nullable_to_non_nullable
as int,idleSeconds: null == idleSeconds ? _self.idleSeconds : idleSeconds // ignore: cast_nullable_to_non_nullable
as int,exePath: freezed == exePath ? _self.exePath : exePath // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
