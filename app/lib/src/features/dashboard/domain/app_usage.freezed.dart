// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'app_usage.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AppUsage {

 String get appName; int get activeSeconds; int get idleSeconds;
/// Create a copy of AppUsage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppUsageCopyWith<AppUsage> get copyWith => _$AppUsageCopyWithImpl<AppUsage>(this as AppUsage, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppUsage&&(identical(other.appName, appName) || other.appName == appName)&&(identical(other.activeSeconds, activeSeconds) || other.activeSeconds == activeSeconds)&&(identical(other.idleSeconds, idleSeconds) || other.idleSeconds == idleSeconds));
}


@override
int get hashCode => Object.hash(runtimeType,appName,activeSeconds,idleSeconds);

@override
String toString() {
  return 'AppUsage(appName: $appName, activeSeconds: $activeSeconds, idleSeconds: $idleSeconds)';
}


}

/// @nodoc
abstract mixin class $AppUsageCopyWith<$Res>  {
  factory $AppUsageCopyWith(AppUsage value, $Res Function(AppUsage) _then) = _$AppUsageCopyWithImpl;
@useResult
$Res call({
 String appName, int activeSeconds, int idleSeconds
});




}
/// @nodoc
class _$AppUsageCopyWithImpl<$Res>
    implements $AppUsageCopyWith<$Res> {
  _$AppUsageCopyWithImpl(this._self, this._then);

  final AppUsage _self;
  final $Res Function(AppUsage) _then;

/// Create a copy of AppUsage
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


/// Adds pattern-matching-related methods to [AppUsage].
extension AppUsagePatterns on AppUsage {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppUsage value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppUsage() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppUsage value)  $default,){
final _that = this;
switch (_that) {
case _AppUsage():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppUsage value)?  $default,){
final _that = this;
switch (_that) {
case _AppUsage() when $default != null:
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
case _AppUsage() when $default != null:
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
case _AppUsage():
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
case _AppUsage() when $default != null:
return $default(_that.appName,_that.activeSeconds,_that.idleSeconds);case _:
  return null;

}
}

}

/// @nodoc


class _AppUsage extends AppUsage {
  const _AppUsage({required this.appName, required this.activeSeconds, required this.idleSeconds}): super._();
  

@override final  String appName;
@override final  int activeSeconds;
@override final  int idleSeconds;

/// Create a copy of AppUsage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppUsageCopyWith<_AppUsage> get copyWith => __$AppUsageCopyWithImpl<_AppUsage>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppUsage&&(identical(other.appName, appName) || other.appName == appName)&&(identical(other.activeSeconds, activeSeconds) || other.activeSeconds == activeSeconds)&&(identical(other.idleSeconds, idleSeconds) || other.idleSeconds == idleSeconds));
}


@override
int get hashCode => Object.hash(runtimeType,appName,activeSeconds,idleSeconds);

@override
String toString() {
  return 'AppUsage(appName: $appName, activeSeconds: $activeSeconds, idleSeconds: $idleSeconds)';
}


}

/// @nodoc
abstract mixin class _$AppUsageCopyWith<$Res> implements $AppUsageCopyWith<$Res> {
  factory _$AppUsageCopyWith(_AppUsage value, $Res Function(_AppUsage) _then) = __$AppUsageCopyWithImpl;
@override @useResult
$Res call({
 String appName, int activeSeconds, int idleSeconds
});




}
/// @nodoc
class __$AppUsageCopyWithImpl<$Res>
    implements _$AppUsageCopyWith<$Res> {
  __$AppUsageCopyWithImpl(this._self, this._then);

  final _AppUsage _self;
  final $Res Function(_AppUsage) _then;

/// Create a copy of AppUsage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? appName = null,Object? activeSeconds = null,Object? idleSeconds = null,}) {
  return _then(_AppUsage(
appName: null == appName ? _self.appName : appName // ignore: cast_nullable_to_non_nullable
as String,activeSeconds: null == activeSeconds ? _self.activeSeconds : activeSeconds // ignore: cast_nullable_to_non_nullable
as int,idleSeconds: null == idleSeconds ? _self.idleSeconds : idleSeconds // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
