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

 List<AppUsageItem> get apps; int get totalActiveSeconds; int get totalIdleSeconds; int get lifetimeSeconds; String? get since;
/// Create a copy of DashboardState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DashboardStateCopyWith<DashboardState> get copyWith => _$DashboardStateCopyWithImpl<DashboardState>(this as DashboardState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DashboardState&&const DeepCollectionEquality().equals(other.apps, apps)&&(identical(other.totalActiveSeconds, totalActiveSeconds) || other.totalActiveSeconds == totalActiveSeconds)&&(identical(other.totalIdleSeconds, totalIdleSeconds) || other.totalIdleSeconds == totalIdleSeconds)&&(identical(other.lifetimeSeconds, lifetimeSeconds) || other.lifetimeSeconds == lifetimeSeconds)&&(identical(other.since, since) || other.since == since));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(apps),totalActiveSeconds,totalIdleSeconds,lifetimeSeconds,since);

@override
String toString() {
  return 'DashboardState(apps: $apps, totalActiveSeconds: $totalActiveSeconds, totalIdleSeconds: $totalIdleSeconds, lifetimeSeconds: $lifetimeSeconds, since: $since)';
}


}

/// @nodoc
abstract mixin class $DashboardStateCopyWith<$Res>  {
  factory $DashboardStateCopyWith(DashboardState value, $Res Function(DashboardState) _then) = _$DashboardStateCopyWithImpl;
@useResult
$Res call({
 List<AppUsageItem> apps, int totalActiveSeconds, int totalIdleSeconds, int lifetimeSeconds, String? since
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
@pragma('vm:prefer-inline') @override $Res call({Object? apps = null,Object? totalActiveSeconds = null,Object? totalIdleSeconds = null,Object? lifetimeSeconds = null,Object? since = freezed,}) {
  return _then(_self.copyWith(
apps: null == apps ? _self.apps : apps // ignore: cast_nullable_to_non_nullable
as List<AppUsageItem>,totalActiveSeconds: null == totalActiveSeconds ? _self.totalActiveSeconds : totalActiveSeconds // ignore: cast_nullable_to_non_nullable
as int,totalIdleSeconds: null == totalIdleSeconds ? _self.totalIdleSeconds : totalIdleSeconds // ignore: cast_nullable_to_non_nullable
as int,lifetimeSeconds: null == lifetimeSeconds ? _self.lifetimeSeconds : lifetimeSeconds // ignore: cast_nullable_to_non_nullable
as int,since: freezed == since ? _self.since : since // ignore: cast_nullable_to_non_nullable
as String?,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<AppUsageItem> apps,  int totalActiveSeconds,  int totalIdleSeconds,  int lifetimeSeconds,  String? since)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DashboardState() when $default != null:
return $default(_that.apps,_that.totalActiveSeconds,_that.totalIdleSeconds,_that.lifetimeSeconds,_that.since);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<AppUsageItem> apps,  int totalActiveSeconds,  int totalIdleSeconds,  int lifetimeSeconds,  String? since)  $default,) {final _that = this;
switch (_that) {
case _DashboardState():
return $default(_that.apps,_that.totalActiveSeconds,_that.totalIdleSeconds,_that.lifetimeSeconds,_that.since);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<AppUsageItem> apps,  int totalActiveSeconds,  int totalIdleSeconds,  int lifetimeSeconds,  String? since)?  $default,) {final _that = this;
switch (_that) {
case _DashboardState() when $default != null:
return $default(_that.apps,_that.totalActiveSeconds,_that.totalIdleSeconds,_that.lifetimeSeconds,_that.since);case _:
  return null;

}
}

}

/// @nodoc


class _DashboardState extends DashboardState {
  const _DashboardState({required final  List<AppUsageItem> apps, required this.totalActiveSeconds, required this.totalIdleSeconds, required this.lifetimeSeconds, this.since}): _apps = apps,super._();
  

 final  List<AppUsageItem> _apps;
@override List<AppUsageItem> get apps {
  if (_apps is EqualUnmodifiableListView) return _apps;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_apps);
}

@override final  int totalActiveSeconds;
@override final  int totalIdleSeconds;
@override final  int lifetimeSeconds;
@override final  String? since;

/// Create a copy of DashboardState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DashboardStateCopyWith<_DashboardState> get copyWith => __$DashboardStateCopyWithImpl<_DashboardState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _DashboardState&&const DeepCollectionEquality().equals(other._apps, _apps)&&(identical(other.totalActiveSeconds, totalActiveSeconds) || other.totalActiveSeconds == totalActiveSeconds)&&(identical(other.totalIdleSeconds, totalIdleSeconds) || other.totalIdleSeconds == totalIdleSeconds)&&(identical(other.lifetimeSeconds, lifetimeSeconds) || other.lifetimeSeconds == lifetimeSeconds)&&(identical(other.since, since) || other.since == since));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_apps),totalActiveSeconds,totalIdleSeconds,lifetimeSeconds,since);

@override
String toString() {
  return 'DashboardState(apps: $apps, totalActiveSeconds: $totalActiveSeconds, totalIdleSeconds: $totalIdleSeconds, lifetimeSeconds: $lifetimeSeconds, since: $since)';
}


}

/// @nodoc
abstract mixin class _$DashboardStateCopyWith<$Res> implements $DashboardStateCopyWith<$Res> {
  factory _$DashboardStateCopyWith(_DashboardState value, $Res Function(_DashboardState) _then) = __$DashboardStateCopyWithImpl;
@override @useResult
$Res call({
 List<AppUsageItem> apps, int totalActiveSeconds, int totalIdleSeconds, int lifetimeSeconds, String? since
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
@override @pragma('vm:prefer-inline') $Res call({Object? apps = null,Object? totalActiveSeconds = null,Object? totalIdleSeconds = null,Object? lifetimeSeconds = null,Object? since = freezed,}) {
  return _then(_DashboardState(
apps: null == apps ? _self._apps : apps // ignore: cast_nullable_to_non_nullable
as List<AppUsageItem>,totalActiveSeconds: null == totalActiveSeconds ? _self.totalActiveSeconds : totalActiveSeconds // ignore: cast_nullable_to_non_nullable
as int,totalIdleSeconds: null == totalIdleSeconds ? _self.totalIdleSeconds : totalIdleSeconds // ignore: cast_nullable_to_non_nullable
as int,lifetimeSeconds: null == lifetimeSeconds ? _self.lifetimeSeconds : lifetimeSeconds // ignore: cast_nullable_to_non_nullable
as int,since: freezed == since ? _self.since : since // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$AppUsageItem {

 String get appName; int get activeSeconds; int get idleSeconds;
/// Create a copy of AppUsageItem
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppUsageItemCopyWith<AppUsageItem> get copyWith => _$AppUsageItemCopyWithImpl<AppUsageItem>(this as AppUsageItem, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppUsageItem&&(identical(other.appName, appName) || other.appName == appName)&&(identical(other.activeSeconds, activeSeconds) || other.activeSeconds == activeSeconds)&&(identical(other.idleSeconds, idleSeconds) || other.idleSeconds == idleSeconds));
}


@override
int get hashCode => Object.hash(runtimeType,appName,activeSeconds,idleSeconds);

@override
String toString() {
  return 'AppUsageItem(appName: $appName, activeSeconds: $activeSeconds, idleSeconds: $idleSeconds)';
}


}

/// @nodoc
abstract mixin class $AppUsageItemCopyWith<$Res>  {
  factory $AppUsageItemCopyWith(AppUsageItem value, $Res Function(AppUsageItem) _then) = _$AppUsageItemCopyWithImpl;
@useResult
$Res call({
 String appName, int activeSeconds, int idleSeconds
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
@pragma('vm:prefer-inline') @override $Res call({Object? appName = null,Object? activeSeconds = null,Object? idleSeconds = null,}) {
  return _then(_self.copyWith(
appName: null == appName ? _self.appName : appName // ignore: cast_nullable_to_non_nullable
as String,activeSeconds: null == activeSeconds ? _self.activeSeconds : activeSeconds // ignore: cast_nullable_to_non_nullable
as int,idleSeconds: null == idleSeconds ? _self.idleSeconds : idleSeconds // ignore: cast_nullable_to_non_nullable
as int,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String appName,  int activeSeconds,  int idleSeconds)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppUsageItem() when $default != null:
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String appName,  int activeSeconds,  int idleSeconds)  $default,) {final _that = this;
switch (_that) {
case _AppUsageItem():
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String appName,  int activeSeconds,  int idleSeconds)?  $default,) {final _that = this;
switch (_that) {
case _AppUsageItem() when $default != null:
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds);case _:
  return null;

}
}

}

/// @nodoc


class _AppUsageItem extends AppUsageItem {
  const _AppUsageItem({required this.appName, required this.activeSeconds, required this.idleSeconds}): super._();
  

@override final  String appName;
@override final  int activeSeconds;
@override final  int idleSeconds;

/// Create a copy of AppUsageItem
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppUsageItemCopyWith<_AppUsageItem> get copyWith => __$AppUsageItemCopyWithImpl<_AppUsageItem>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppUsageItem&&(identical(other.appName, appName) || other.appName == appName)&&(identical(other.activeSeconds, activeSeconds) || other.activeSeconds == activeSeconds)&&(identical(other.idleSeconds, idleSeconds) || other.idleSeconds == idleSeconds));
}


@override
int get hashCode => Object.hash(runtimeType,appName,activeSeconds,idleSeconds);

@override
String toString() {
  return 'AppUsageItem(appName: $appName, activeSeconds: $activeSeconds, idleSeconds: $idleSeconds)';
}


}

/// @nodoc
abstract mixin class _$AppUsageItemCopyWith<$Res> implements $AppUsageItemCopyWith<$Res> {
  factory _$AppUsageItemCopyWith(_AppUsageItem value, $Res Function(_AppUsageItem) _then) = __$AppUsageItemCopyWithImpl;
@override @useResult
$Res call({
 String appName, int activeSeconds, int idleSeconds
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
@override @pragma('vm:prefer-inline') $Res call({Object? appName = null,Object? activeSeconds = null,Object? idleSeconds = null,}) {
  return _then(_AppUsageItem(
appName: null == appName ? _self.appName : appName // ignore: cast_nullable_to_non_nullable
as String,activeSeconds: null == activeSeconds ? _self.activeSeconds : activeSeconds // ignore: cast_nullable_to_non_nullable
as int,idleSeconds: null == idleSeconds ? _self.idleSeconds : idleSeconds // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
