// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'accounting.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AccountingAsOfRequest {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingAsOfRequest);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AccountingAsOfRequest()';
}


}

/// @nodoc
class $AccountingAsOfRequestCopyWith<$Res>  {
$AccountingAsOfRequestCopyWith(AccountingAsOfRequest _, $Res Function(AccountingAsOfRequest) __);
}


/// Adds pattern-matching-related methods to [AccountingAsOfRequest].
extension AccountingAsOfRequestPatterns on AccountingAsOfRequest {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AccountingAsOfRequest_Current value)?  current,TResult Function( AccountingAsOfRequest_At value)?  at,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AccountingAsOfRequest_Current() when current != null:
return current(_that);case AccountingAsOfRequest_At() when at != null:
return at(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AccountingAsOfRequest_Current value)  current,required TResult Function( AccountingAsOfRequest_At value)  at,}){
final _that = this;
switch (_that) {
case AccountingAsOfRequest_Current():
return current(_that);case AccountingAsOfRequest_At():
return at(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AccountingAsOfRequest_Current value)?  current,TResult? Function( AccountingAsOfRequest_At value)?  at,}){
final _that = this;
switch (_that) {
case AccountingAsOfRequest_Current() when current != null:
return current(_that);case AccountingAsOfRequest_At() when at != null:
return at(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  current,TResult Function( String asOfUtc)?  at,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AccountingAsOfRequest_Current() when current != null:
return current();case AccountingAsOfRequest_At() when at != null:
return at(_that.asOfUtc);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  current,required TResult Function( String asOfUtc)  at,}) {final _that = this;
switch (_that) {
case AccountingAsOfRequest_Current():
return current();case AccountingAsOfRequest_At():
return at(_that.asOfUtc);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  current,TResult? Function( String asOfUtc)?  at,}) {final _that = this;
switch (_that) {
case AccountingAsOfRequest_Current() when current != null:
return current();case AccountingAsOfRequest_At() when at != null:
return at(_that.asOfUtc);case _:
  return null;

}
}

}

/// @nodoc


class AccountingAsOfRequest_Current extends AccountingAsOfRequest {
  const AccountingAsOfRequest_Current(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingAsOfRequest_Current);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AccountingAsOfRequest.current()';
}


}




/// @nodoc


class AccountingAsOfRequest_At extends AccountingAsOfRequest {
  const AccountingAsOfRequest_At({required this.asOfUtc}): super._();
  

 final  String asOfUtc;

/// Create a copy of AccountingAsOfRequest
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingAsOfRequest_AtCopyWith<AccountingAsOfRequest_At> get copyWith => _$AccountingAsOfRequest_AtCopyWithImpl<AccountingAsOfRequest_At>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingAsOfRequest_At&&(identical(other.asOfUtc, asOfUtc) || other.asOfUtc == asOfUtc));
}


@override
int get hashCode => Object.hash(runtimeType,asOfUtc);

@override
String toString() {
  return 'AccountingAsOfRequest.at(asOfUtc: $asOfUtc)';
}


}

/// @nodoc
abstract mixin class $AccountingAsOfRequest_AtCopyWith<$Res> implements $AccountingAsOfRequestCopyWith<$Res> {
  factory $AccountingAsOfRequest_AtCopyWith(AccountingAsOfRequest_At value, $Res Function(AccountingAsOfRequest_At) _then) = _$AccountingAsOfRequest_AtCopyWithImpl;
@useResult
$Res call({
 String asOfUtc
});




}
/// @nodoc
class _$AccountingAsOfRequest_AtCopyWithImpl<$Res>
    implements $AccountingAsOfRequest_AtCopyWith<$Res> {
  _$AccountingAsOfRequest_AtCopyWithImpl(this._self, this._then);

  final AccountingAsOfRequest_At _self;
  final $Res Function(AccountingAsOfRequest_At) _then;

/// Create a copy of AccountingAsOfRequest
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? asOfUtc = null,}) {
  return _then(AccountingAsOfRequest_At(
asOfUtc: null == asOfUtc ? _self.asOfUtc : asOfUtc // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$AccountingBridgeError {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AccountingBridgeError()';
}


}

/// @nodoc
class $AccountingBridgeErrorCopyWith<$Res>  {
$AccountingBridgeErrorCopyWith(AccountingBridgeError _, $Res Function(AccountingBridgeError) __);
}


/// Adds pattern-matching-related methods to [AccountingBridgeError].
extension AccountingBridgeErrorPatterns on AccountingBridgeError {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AccountingBridgeError_InvalidUtcTimestamp value)?  invalidUtcTimestamp,TResult Function( AccountingBridgeError_InvalidLocalDate value)?  invalidLocalDate,TResult Function( AccountingBridgeError_InvalidDateRange value)?  invalidDateRange,TResult Function( AccountingBridgeError_InvalidRange value)?  invalidRange,TResult Function( AccountingBridgeError_AsOfBeforeStart value)?  asOfBeforeStart,TResult Function( AccountingBridgeError_FutureAsOf value)?  futureAsOf,TResult Function( AccountingBridgeError_InvalidTimeZone value)?  invalidTimeZone,TResult Function( AccountingBridgeError_InvalidLocalBoundary value)?  invalidLocalBoundary,TResult Function( AccountingBridgeError_Storage value)?  storage,TResult Function( AccountingBridgeError_StaleRevision value)?  staleRevision,TResult Function( AccountingBridgeError_ProducerUnavailable value)?  producerUnavailable,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AccountingBridgeError_InvalidUtcTimestamp() when invalidUtcTimestamp != null:
return invalidUtcTimestamp(_that);case AccountingBridgeError_InvalidLocalDate() when invalidLocalDate != null:
return invalidLocalDate(_that);case AccountingBridgeError_InvalidDateRange() when invalidDateRange != null:
return invalidDateRange(_that);case AccountingBridgeError_InvalidRange() when invalidRange != null:
return invalidRange(_that);case AccountingBridgeError_AsOfBeforeStart() when asOfBeforeStart != null:
return asOfBeforeStart(_that);case AccountingBridgeError_FutureAsOf() when futureAsOf != null:
return futureAsOf(_that);case AccountingBridgeError_InvalidTimeZone() when invalidTimeZone != null:
return invalidTimeZone(_that);case AccountingBridgeError_InvalidLocalBoundary() when invalidLocalBoundary != null:
return invalidLocalBoundary(_that);case AccountingBridgeError_Storage() when storage != null:
return storage(_that);case AccountingBridgeError_StaleRevision() when staleRevision != null:
return staleRevision(_that);case AccountingBridgeError_ProducerUnavailable() when producerUnavailable != null:
return producerUnavailable(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AccountingBridgeError_InvalidUtcTimestamp value)  invalidUtcTimestamp,required TResult Function( AccountingBridgeError_InvalidLocalDate value)  invalidLocalDate,required TResult Function( AccountingBridgeError_InvalidDateRange value)  invalidDateRange,required TResult Function( AccountingBridgeError_InvalidRange value)  invalidRange,required TResult Function( AccountingBridgeError_AsOfBeforeStart value)  asOfBeforeStart,required TResult Function( AccountingBridgeError_FutureAsOf value)  futureAsOf,required TResult Function( AccountingBridgeError_InvalidTimeZone value)  invalidTimeZone,required TResult Function( AccountingBridgeError_InvalidLocalBoundary value)  invalidLocalBoundary,required TResult Function( AccountingBridgeError_Storage value)  storage,required TResult Function( AccountingBridgeError_StaleRevision value)  staleRevision,required TResult Function( AccountingBridgeError_ProducerUnavailable value)  producerUnavailable,}){
final _that = this;
switch (_that) {
case AccountingBridgeError_InvalidUtcTimestamp():
return invalidUtcTimestamp(_that);case AccountingBridgeError_InvalidLocalDate():
return invalidLocalDate(_that);case AccountingBridgeError_InvalidDateRange():
return invalidDateRange(_that);case AccountingBridgeError_InvalidRange():
return invalidRange(_that);case AccountingBridgeError_AsOfBeforeStart():
return asOfBeforeStart(_that);case AccountingBridgeError_FutureAsOf():
return futureAsOf(_that);case AccountingBridgeError_InvalidTimeZone():
return invalidTimeZone(_that);case AccountingBridgeError_InvalidLocalBoundary():
return invalidLocalBoundary(_that);case AccountingBridgeError_Storage():
return storage(_that);case AccountingBridgeError_StaleRevision():
return staleRevision(_that);case AccountingBridgeError_ProducerUnavailable():
return producerUnavailable(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AccountingBridgeError_InvalidUtcTimestamp value)?  invalidUtcTimestamp,TResult? Function( AccountingBridgeError_InvalidLocalDate value)?  invalidLocalDate,TResult? Function( AccountingBridgeError_InvalidDateRange value)?  invalidDateRange,TResult? Function( AccountingBridgeError_InvalidRange value)?  invalidRange,TResult? Function( AccountingBridgeError_AsOfBeforeStart value)?  asOfBeforeStart,TResult? Function( AccountingBridgeError_FutureAsOf value)?  futureAsOf,TResult? Function( AccountingBridgeError_InvalidTimeZone value)?  invalidTimeZone,TResult? Function( AccountingBridgeError_InvalidLocalBoundary value)?  invalidLocalBoundary,TResult? Function( AccountingBridgeError_Storage value)?  storage,TResult? Function( AccountingBridgeError_StaleRevision value)?  staleRevision,TResult? Function( AccountingBridgeError_ProducerUnavailable value)?  producerUnavailable,}){
final _that = this;
switch (_that) {
case AccountingBridgeError_InvalidUtcTimestamp() when invalidUtcTimestamp != null:
return invalidUtcTimestamp(_that);case AccountingBridgeError_InvalidLocalDate() when invalidLocalDate != null:
return invalidLocalDate(_that);case AccountingBridgeError_InvalidDateRange() when invalidDateRange != null:
return invalidDateRange(_that);case AccountingBridgeError_InvalidRange() when invalidRange != null:
return invalidRange(_that);case AccountingBridgeError_AsOfBeforeStart() when asOfBeforeStart != null:
return asOfBeforeStart(_that);case AccountingBridgeError_FutureAsOf() when futureAsOf != null:
return futureAsOf(_that);case AccountingBridgeError_InvalidTimeZone() when invalidTimeZone != null:
return invalidTimeZone(_that);case AccountingBridgeError_InvalidLocalBoundary() when invalidLocalBoundary != null:
return invalidLocalBoundary(_that);case AccountingBridgeError_Storage() when storage != null:
return storage(_that);case AccountingBridgeError_StaleRevision() when staleRevision != null:
return staleRevision(_that);case AccountingBridgeError_ProducerUnavailable() when producerUnavailable != null:
return producerUnavailable(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field,  String value)?  invalidUtcTimestamp,TResult Function( String value)?  invalidLocalDate,TResult Function( String start,  String end)?  invalidDateRange,TResult Function( String startUtc,  String endUtc)?  invalidRange,TResult Function( String asOfUtc,  String startUtc)?  asOfBeforeStart,TResult Function( String asOfUtc,  String deadlineUtc)?  futureAsOf,TResult Function( String timezone)?  invalidTimeZone,TResult Function( String timezone,  String boundary)?  invalidLocalBoundary,TResult Function( String message)?  storage,TResult Function( String sourceIdentity,  PlatformInt64 incoming,  PlatformInt64 existing)?  staleRevision,TResult Function( String message)?  producerUnavailable,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AccountingBridgeError_InvalidUtcTimestamp() when invalidUtcTimestamp != null:
return invalidUtcTimestamp(_that.field,_that.value);case AccountingBridgeError_InvalidLocalDate() when invalidLocalDate != null:
return invalidLocalDate(_that.value);case AccountingBridgeError_InvalidDateRange() when invalidDateRange != null:
return invalidDateRange(_that.start,_that.end);case AccountingBridgeError_InvalidRange() when invalidRange != null:
return invalidRange(_that.startUtc,_that.endUtc);case AccountingBridgeError_AsOfBeforeStart() when asOfBeforeStart != null:
return asOfBeforeStart(_that.asOfUtc,_that.startUtc);case AccountingBridgeError_FutureAsOf() when futureAsOf != null:
return futureAsOf(_that.asOfUtc,_that.deadlineUtc);case AccountingBridgeError_InvalidTimeZone() when invalidTimeZone != null:
return invalidTimeZone(_that.timezone);case AccountingBridgeError_InvalidLocalBoundary() when invalidLocalBoundary != null:
return invalidLocalBoundary(_that.timezone,_that.boundary);case AccountingBridgeError_Storage() when storage != null:
return storage(_that.message);case AccountingBridgeError_StaleRevision() when staleRevision != null:
return staleRevision(_that.sourceIdentity,_that.incoming,_that.existing);case AccountingBridgeError_ProducerUnavailable() when producerUnavailable != null:
return producerUnavailable(_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field,  String value)  invalidUtcTimestamp,required TResult Function( String value)  invalidLocalDate,required TResult Function( String start,  String end)  invalidDateRange,required TResult Function( String startUtc,  String endUtc)  invalidRange,required TResult Function( String asOfUtc,  String startUtc)  asOfBeforeStart,required TResult Function( String asOfUtc,  String deadlineUtc)  futureAsOf,required TResult Function( String timezone)  invalidTimeZone,required TResult Function( String timezone,  String boundary)  invalidLocalBoundary,required TResult Function( String message)  storage,required TResult Function( String sourceIdentity,  PlatformInt64 incoming,  PlatformInt64 existing)  staleRevision,required TResult Function( String message)  producerUnavailable,}) {final _that = this;
switch (_that) {
case AccountingBridgeError_InvalidUtcTimestamp():
return invalidUtcTimestamp(_that.field,_that.value);case AccountingBridgeError_InvalidLocalDate():
return invalidLocalDate(_that.value);case AccountingBridgeError_InvalidDateRange():
return invalidDateRange(_that.start,_that.end);case AccountingBridgeError_InvalidRange():
return invalidRange(_that.startUtc,_that.endUtc);case AccountingBridgeError_AsOfBeforeStart():
return asOfBeforeStart(_that.asOfUtc,_that.startUtc);case AccountingBridgeError_FutureAsOf():
return futureAsOf(_that.asOfUtc,_that.deadlineUtc);case AccountingBridgeError_InvalidTimeZone():
return invalidTimeZone(_that.timezone);case AccountingBridgeError_InvalidLocalBoundary():
return invalidLocalBoundary(_that.timezone,_that.boundary);case AccountingBridgeError_Storage():
return storage(_that.message);case AccountingBridgeError_StaleRevision():
return staleRevision(_that.sourceIdentity,_that.incoming,_that.existing);case AccountingBridgeError_ProducerUnavailable():
return producerUnavailable(_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field,  String value)?  invalidUtcTimestamp,TResult? Function( String value)?  invalidLocalDate,TResult? Function( String start,  String end)?  invalidDateRange,TResult? Function( String startUtc,  String endUtc)?  invalidRange,TResult? Function( String asOfUtc,  String startUtc)?  asOfBeforeStart,TResult? Function( String asOfUtc,  String deadlineUtc)?  futureAsOf,TResult? Function( String timezone)?  invalidTimeZone,TResult? Function( String timezone,  String boundary)?  invalidLocalBoundary,TResult? Function( String message)?  storage,TResult? Function( String sourceIdentity,  PlatformInt64 incoming,  PlatformInt64 existing)?  staleRevision,TResult? Function( String message)?  producerUnavailable,}) {final _that = this;
switch (_that) {
case AccountingBridgeError_InvalidUtcTimestamp() when invalidUtcTimestamp != null:
return invalidUtcTimestamp(_that.field,_that.value);case AccountingBridgeError_InvalidLocalDate() when invalidLocalDate != null:
return invalidLocalDate(_that.value);case AccountingBridgeError_InvalidDateRange() when invalidDateRange != null:
return invalidDateRange(_that.start,_that.end);case AccountingBridgeError_InvalidRange() when invalidRange != null:
return invalidRange(_that.startUtc,_that.endUtc);case AccountingBridgeError_AsOfBeforeStart() when asOfBeforeStart != null:
return asOfBeforeStart(_that.asOfUtc,_that.startUtc);case AccountingBridgeError_FutureAsOf() when futureAsOf != null:
return futureAsOf(_that.asOfUtc,_that.deadlineUtc);case AccountingBridgeError_InvalidTimeZone() when invalidTimeZone != null:
return invalidTimeZone(_that.timezone);case AccountingBridgeError_InvalidLocalBoundary() when invalidLocalBoundary != null:
return invalidLocalBoundary(_that.timezone,_that.boundary);case AccountingBridgeError_Storage() when storage != null:
return storage(_that.message);case AccountingBridgeError_StaleRevision() when staleRevision != null:
return staleRevision(_that.sourceIdentity,_that.incoming,_that.existing);case AccountingBridgeError_ProducerUnavailable() when producerUnavailable != null:
return producerUnavailable(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class AccountingBridgeError_InvalidUtcTimestamp extends AccountingBridgeError {
  const AccountingBridgeError_InvalidUtcTimestamp({required this.field, required this.value}): super._();
  

 final  String field;
 final  String value;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_InvalidUtcTimestampCopyWith<AccountingBridgeError_InvalidUtcTimestamp> get copyWith => _$AccountingBridgeError_InvalidUtcTimestampCopyWithImpl<AccountingBridgeError_InvalidUtcTimestamp>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_InvalidUtcTimestamp&&(identical(other.field, field) || other.field == field)&&(identical(other.value, value) || other.value == value));
}


@override
int get hashCode => Object.hash(runtimeType,field,value);

@override
String toString() {
  return 'AccountingBridgeError.invalidUtcTimestamp(field: $field, value: $value)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_InvalidUtcTimestampCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_InvalidUtcTimestampCopyWith(AccountingBridgeError_InvalidUtcTimestamp value, $Res Function(AccountingBridgeError_InvalidUtcTimestamp) _then) = _$AccountingBridgeError_InvalidUtcTimestampCopyWithImpl;
@useResult
$Res call({
 String field, String value
});




}
/// @nodoc
class _$AccountingBridgeError_InvalidUtcTimestampCopyWithImpl<$Res>
    implements $AccountingBridgeError_InvalidUtcTimestampCopyWith<$Res> {
  _$AccountingBridgeError_InvalidUtcTimestampCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_InvalidUtcTimestamp _self;
  final $Res Function(AccountingBridgeError_InvalidUtcTimestamp) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field = null,Object? value = null,}) {
  return _then(AccountingBridgeError_InvalidUtcTimestamp(
field: null == field ? _self.field : field // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_InvalidLocalDate extends AccountingBridgeError {
  const AccountingBridgeError_InvalidLocalDate({required this.value}): super._();
  

 final  String value;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_InvalidLocalDateCopyWith<AccountingBridgeError_InvalidLocalDate> get copyWith => _$AccountingBridgeError_InvalidLocalDateCopyWithImpl<AccountingBridgeError_InvalidLocalDate>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_InvalidLocalDate&&(identical(other.value, value) || other.value == value));
}


@override
int get hashCode => Object.hash(runtimeType,value);

@override
String toString() {
  return 'AccountingBridgeError.invalidLocalDate(value: $value)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_InvalidLocalDateCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_InvalidLocalDateCopyWith(AccountingBridgeError_InvalidLocalDate value, $Res Function(AccountingBridgeError_InvalidLocalDate) _then) = _$AccountingBridgeError_InvalidLocalDateCopyWithImpl;
@useResult
$Res call({
 String value
});




}
/// @nodoc
class _$AccountingBridgeError_InvalidLocalDateCopyWithImpl<$Res>
    implements $AccountingBridgeError_InvalidLocalDateCopyWith<$Res> {
  _$AccountingBridgeError_InvalidLocalDateCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_InvalidLocalDate _self;
  final $Res Function(AccountingBridgeError_InvalidLocalDate) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? value = null,}) {
  return _then(AccountingBridgeError_InvalidLocalDate(
value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_InvalidDateRange extends AccountingBridgeError {
  const AccountingBridgeError_InvalidDateRange({required this.start, required this.end}): super._();
  

 final  String start;
 final  String end;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_InvalidDateRangeCopyWith<AccountingBridgeError_InvalidDateRange> get copyWith => _$AccountingBridgeError_InvalidDateRangeCopyWithImpl<AccountingBridgeError_InvalidDateRange>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_InvalidDateRange&&(identical(other.start, start) || other.start == start)&&(identical(other.end, end) || other.end == end));
}


@override
int get hashCode => Object.hash(runtimeType,start,end);

@override
String toString() {
  return 'AccountingBridgeError.invalidDateRange(start: $start, end: $end)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_InvalidDateRangeCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_InvalidDateRangeCopyWith(AccountingBridgeError_InvalidDateRange value, $Res Function(AccountingBridgeError_InvalidDateRange) _then) = _$AccountingBridgeError_InvalidDateRangeCopyWithImpl;
@useResult
$Res call({
 String start, String end
});




}
/// @nodoc
class _$AccountingBridgeError_InvalidDateRangeCopyWithImpl<$Res>
    implements $AccountingBridgeError_InvalidDateRangeCopyWith<$Res> {
  _$AccountingBridgeError_InvalidDateRangeCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_InvalidDateRange _self;
  final $Res Function(AccountingBridgeError_InvalidDateRange) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? start = null,Object? end = null,}) {
  return _then(AccountingBridgeError_InvalidDateRange(
start: null == start ? _self.start : start // ignore: cast_nullable_to_non_nullable
as String,end: null == end ? _self.end : end // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_InvalidRange extends AccountingBridgeError {
  const AccountingBridgeError_InvalidRange({required this.startUtc, required this.endUtc}): super._();
  

 final  String startUtc;
 final  String endUtc;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_InvalidRangeCopyWith<AccountingBridgeError_InvalidRange> get copyWith => _$AccountingBridgeError_InvalidRangeCopyWithImpl<AccountingBridgeError_InvalidRange>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_InvalidRange&&(identical(other.startUtc, startUtc) || other.startUtc == startUtc)&&(identical(other.endUtc, endUtc) || other.endUtc == endUtc));
}


@override
int get hashCode => Object.hash(runtimeType,startUtc,endUtc);

@override
String toString() {
  return 'AccountingBridgeError.invalidRange(startUtc: $startUtc, endUtc: $endUtc)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_InvalidRangeCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_InvalidRangeCopyWith(AccountingBridgeError_InvalidRange value, $Res Function(AccountingBridgeError_InvalidRange) _then) = _$AccountingBridgeError_InvalidRangeCopyWithImpl;
@useResult
$Res call({
 String startUtc, String endUtc
});




}
/// @nodoc
class _$AccountingBridgeError_InvalidRangeCopyWithImpl<$Res>
    implements $AccountingBridgeError_InvalidRangeCopyWith<$Res> {
  _$AccountingBridgeError_InvalidRangeCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_InvalidRange _self;
  final $Res Function(AccountingBridgeError_InvalidRange) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? startUtc = null,Object? endUtc = null,}) {
  return _then(AccountingBridgeError_InvalidRange(
startUtc: null == startUtc ? _self.startUtc : startUtc // ignore: cast_nullable_to_non_nullable
as String,endUtc: null == endUtc ? _self.endUtc : endUtc // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_AsOfBeforeStart extends AccountingBridgeError {
  const AccountingBridgeError_AsOfBeforeStart({required this.asOfUtc, required this.startUtc}): super._();
  

 final  String asOfUtc;
 final  String startUtc;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_AsOfBeforeStartCopyWith<AccountingBridgeError_AsOfBeforeStart> get copyWith => _$AccountingBridgeError_AsOfBeforeStartCopyWithImpl<AccountingBridgeError_AsOfBeforeStart>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_AsOfBeforeStart&&(identical(other.asOfUtc, asOfUtc) || other.asOfUtc == asOfUtc)&&(identical(other.startUtc, startUtc) || other.startUtc == startUtc));
}


@override
int get hashCode => Object.hash(runtimeType,asOfUtc,startUtc);

@override
String toString() {
  return 'AccountingBridgeError.asOfBeforeStart(asOfUtc: $asOfUtc, startUtc: $startUtc)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_AsOfBeforeStartCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_AsOfBeforeStartCopyWith(AccountingBridgeError_AsOfBeforeStart value, $Res Function(AccountingBridgeError_AsOfBeforeStart) _then) = _$AccountingBridgeError_AsOfBeforeStartCopyWithImpl;
@useResult
$Res call({
 String asOfUtc, String startUtc
});




}
/// @nodoc
class _$AccountingBridgeError_AsOfBeforeStartCopyWithImpl<$Res>
    implements $AccountingBridgeError_AsOfBeforeStartCopyWith<$Res> {
  _$AccountingBridgeError_AsOfBeforeStartCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_AsOfBeforeStart _self;
  final $Res Function(AccountingBridgeError_AsOfBeforeStart) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? asOfUtc = null,Object? startUtc = null,}) {
  return _then(AccountingBridgeError_AsOfBeforeStart(
asOfUtc: null == asOfUtc ? _self.asOfUtc : asOfUtc // ignore: cast_nullable_to_non_nullable
as String,startUtc: null == startUtc ? _self.startUtc : startUtc // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_FutureAsOf extends AccountingBridgeError {
  const AccountingBridgeError_FutureAsOf({required this.asOfUtc, required this.deadlineUtc}): super._();
  

 final  String asOfUtc;
 final  String deadlineUtc;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_FutureAsOfCopyWith<AccountingBridgeError_FutureAsOf> get copyWith => _$AccountingBridgeError_FutureAsOfCopyWithImpl<AccountingBridgeError_FutureAsOf>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_FutureAsOf&&(identical(other.asOfUtc, asOfUtc) || other.asOfUtc == asOfUtc)&&(identical(other.deadlineUtc, deadlineUtc) || other.deadlineUtc == deadlineUtc));
}


@override
int get hashCode => Object.hash(runtimeType,asOfUtc,deadlineUtc);

@override
String toString() {
  return 'AccountingBridgeError.futureAsOf(asOfUtc: $asOfUtc, deadlineUtc: $deadlineUtc)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_FutureAsOfCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_FutureAsOfCopyWith(AccountingBridgeError_FutureAsOf value, $Res Function(AccountingBridgeError_FutureAsOf) _then) = _$AccountingBridgeError_FutureAsOfCopyWithImpl;
@useResult
$Res call({
 String asOfUtc, String deadlineUtc
});




}
/// @nodoc
class _$AccountingBridgeError_FutureAsOfCopyWithImpl<$Res>
    implements $AccountingBridgeError_FutureAsOfCopyWith<$Res> {
  _$AccountingBridgeError_FutureAsOfCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_FutureAsOf _self;
  final $Res Function(AccountingBridgeError_FutureAsOf) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? asOfUtc = null,Object? deadlineUtc = null,}) {
  return _then(AccountingBridgeError_FutureAsOf(
asOfUtc: null == asOfUtc ? _self.asOfUtc : asOfUtc // ignore: cast_nullable_to_non_nullable
as String,deadlineUtc: null == deadlineUtc ? _self.deadlineUtc : deadlineUtc // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_InvalidTimeZone extends AccountingBridgeError {
  const AccountingBridgeError_InvalidTimeZone({required this.timezone}): super._();
  

 final  String timezone;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_InvalidTimeZoneCopyWith<AccountingBridgeError_InvalidTimeZone> get copyWith => _$AccountingBridgeError_InvalidTimeZoneCopyWithImpl<AccountingBridgeError_InvalidTimeZone>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_InvalidTimeZone&&(identical(other.timezone, timezone) || other.timezone == timezone));
}


@override
int get hashCode => Object.hash(runtimeType,timezone);

@override
String toString() {
  return 'AccountingBridgeError.invalidTimeZone(timezone: $timezone)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_InvalidTimeZoneCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_InvalidTimeZoneCopyWith(AccountingBridgeError_InvalidTimeZone value, $Res Function(AccountingBridgeError_InvalidTimeZone) _then) = _$AccountingBridgeError_InvalidTimeZoneCopyWithImpl;
@useResult
$Res call({
 String timezone
});




}
/// @nodoc
class _$AccountingBridgeError_InvalidTimeZoneCopyWithImpl<$Res>
    implements $AccountingBridgeError_InvalidTimeZoneCopyWith<$Res> {
  _$AccountingBridgeError_InvalidTimeZoneCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_InvalidTimeZone _self;
  final $Res Function(AccountingBridgeError_InvalidTimeZone) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? timezone = null,}) {
  return _then(AccountingBridgeError_InvalidTimeZone(
timezone: null == timezone ? _self.timezone : timezone // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_InvalidLocalBoundary extends AccountingBridgeError {
  const AccountingBridgeError_InvalidLocalBoundary({required this.timezone, required this.boundary}): super._();
  

 final  String timezone;
 final  String boundary;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_InvalidLocalBoundaryCopyWith<AccountingBridgeError_InvalidLocalBoundary> get copyWith => _$AccountingBridgeError_InvalidLocalBoundaryCopyWithImpl<AccountingBridgeError_InvalidLocalBoundary>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_InvalidLocalBoundary&&(identical(other.timezone, timezone) || other.timezone == timezone)&&(identical(other.boundary, boundary) || other.boundary == boundary));
}


@override
int get hashCode => Object.hash(runtimeType,timezone,boundary);

@override
String toString() {
  return 'AccountingBridgeError.invalidLocalBoundary(timezone: $timezone, boundary: $boundary)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_InvalidLocalBoundaryCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_InvalidLocalBoundaryCopyWith(AccountingBridgeError_InvalidLocalBoundary value, $Res Function(AccountingBridgeError_InvalidLocalBoundary) _then) = _$AccountingBridgeError_InvalidLocalBoundaryCopyWithImpl;
@useResult
$Res call({
 String timezone, String boundary
});




}
/// @nodoc
class _$AccountingBridgeError_InvalidLocalBoundaryCopyWithImpl<$Res>
    implements $AccountingBridgeError_InvalidLocalBoundaryCopyWith<$Res> {
  _$AccountingBridgeError_InvalidLocalBoundaryCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_InvalidLocalBoundary _self;
  final $Res Function(AccountingBridgeError_InvalidLocalBoundary) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? timezone = null,Object? boundary = null,}) {
  return _then(AccountingBridgeError_InvalidLocalBoundary(
timezone: null == timezone ? _self.timezone : timezone // ignore: cast_nullable_to_non_nullable
as String,boundary: null == boundary ? _self.boundary : boundary // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_Storage extends AccountingBridgeError {
  const AccountingBridgeError_Storage({required this.message}): super._();
  

 final  String message;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_StorageCopyWith<AccountingBridgeError_Storage> get copyWith => _$AccountingBridgeError_StorageCopyWithImpl<AccountingBridgeError_Storage>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_Storage&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'AccountingBridgeError.storage(message: $message)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_StorageCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_StorageCopyWith(AccountingBridgeError_Storage value, $Res Function(AccountingBridgeError_Storage) _then) = _$AccountingBridgeError_StorageCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$AccountingBridgeError_StorageCopyWithImpl<$Res>
    implements $AccountingBridgeError_StorageCopyWith<$Res> {
  _$AccountingBridgeError_StorageCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_Storage _self;
  final $Res Function(AccountingBridgeError_Storage) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(AccountingBridgeError_Storage(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingBridgeError_StaleRevision extends AccountingBridgeError {
  const AccountingBridgeError_StaleRevision({required this.sourceIdentity, required this.incoming, required this.existing}): super._();
  

 final  String sourceIdentity;
 final  PlatformInt64 incoming;
 final  PlatformInt64 existing;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_StaleRevisionCopyWith<AccountingBridgeError_StaleRevision> get copyWith => _$AccountingBridgeError_StaleRevisionCopyWithImpl<AccountingBridgeError_StaleRevision>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_StaleRevision&&(identical(other.sourceIdentity, sourceIdentity) || other.sourceIdentity == sourceIdentity)&&(identical(other.incoming, incoming) || other.incoming == incoming)&&(identical(other.existing, existing) || other.existing == existing));
}


@override
int get hashCode => Object.hash(runtimeType,sourceIdentity,incoming,existing);

@override
String toString() {
  return 'AccountingBridgeError.staleRevision(sourceIdentity: $sourceIdentity, incoming: $incoming, existing: $existing)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_StaleRevisionCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_StaleRevisionCopyWith(AccountingBridgeError_StaleRevision value, $Res Function(AccountingBridgeError_StaleRevision) _then) = _$AccountingBridgeError_StaleRevisionCopyWithImpl;
@useResult
$Res call({
 String sourceIdentity, PlatformInt64 incoming, PlatformInt64 existing
});




}
/// @nodoc
class _$AccountingBridgeError_StaleRevisionCopyWithImpl<$Res>
    implements $AccountingBridgeError_StaleRevisionCopyWith<$Res> {
  _$AccountingBridgeError_StaleRevisionCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_StaleRevision _self;
  final $Res Function(AccountingBridgeError_StaleRevision) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sourceIdentity = null,Object? incoming = null,Object? existing = null,}) {
  return _then(AccountingBridgeError_StaleRevision(
sourceIdentity: null == sourceIdentity ? _self.sourceIdentity : sourceIdentity // ignore: cast_nullable_to_non_nullable
as String,incoming: null == incoming ? _self.incoming : incoming // ignore: cast_nullable_to_non_nullable
as PlatformInt64,existing: null == existing ? _self.existing : existing // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class AccountingBridgeError_ProducerUnavailable extends AccountingBridgeError {
  const AccountingBridgeError_ProducerUnavailable({required this.message}): super._();
  

 final  String message;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingBridgeError_ProducerUnavailableCopyWith<AccountingBridgeError_ProducerUnavailable> get copyWith => _$AccountingBridgeError_ProducerUnavailableCopyWithImpl<AccountingBridgeError_ProducerUnavailable>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingBridgeError_ProducerUnavailable&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'AccountingBridgeError.producerUnavailable(message: $message)';
}


}

/// @nodoc
abstract mixin class $AccountingBridgeError_ProducerUnavailableCopyWith<$Res> implements $AccountingBridgeErrorCopyWith<$Res> {
  factory $AccountingBridgeError_ProducerUnavailableCopyWith(AccountingBridgeError_ProducerUnavailable value, $Res Function(AccountingBridgeError_ProducerUnavailable) _then) = _$AccountingBridgeError_ProducerUnavailableCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$AccountingBridgeError_ProducerUnavailableCopyWithImpl<$Res>
    implements $AccountingBridgeError_ProducerUnavailableCopyWith<$Res> {
  _$AccountingBridgeError_ProducerUnavailableCopyWithImpl(this._self, this._then);

  final AccountingBridgeError_ProducerUnavailable _self;
  final $Res Function(AccountingBridgeError_ProducerUnavailable) _then;

/// Create a copy of AccountingBridgeError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(AccountingBridgeError_ProducerUnavailable(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$AccountingRangeRequest {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingRangeRequest);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AccountingRangeRequest()';
}


}

/// @nodoc
class $AccountingRangeRequestCopyWith<$Res>  {
$AccountingRangeRequestCopyWith(AccountingRangeRequest _, $Res Function(AccountingRangeRequest) __);
}


/// Adds pattern-matching-related methods to [AccountingRangeRequest].
extension AccountingRangeRequestPatterns on AccountingRangeRequest {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AccountingRangeRequest_Utc value)?  utc,TResult Function( AccountingRangeRequest_LocalDate value)?  localDate,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AccountingRangeRequest_Utc() when utc != null:
return utc(_that);case AccountingRangeRequest_LocalDate() when localDate != null:
return localDate(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AccountingRangeRequest_Utc value)  utc,required TResult Function( AccountingRangeRequest_LocalDate value)  localDate,}){
final _that = this;
switch (_that) {
case AccountingRangeRequest_Utc():
return utc(_that);case AccountingRangeRequest_LocalDate():
return localDate(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AccountingRangeRequest_Utc value)?  utc,TResult? Function( AccountingRangeRequest_LocalDate value)?  localDate,}){
final _that = this;
switch (_that) {
case AccountingRangeRequest_Utc() when utc != null:
return utc(_that);case AccountingRangeRequest_LocalDate() when localDate != null:
return localDate(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String startUtc,  String endUtc)?  utc,TResult Function( String localDate,  String timezone)?  localDate,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AccountingRangeRequest_Utc() when utc != null:
return utc(_that.startUtc,_that.endUtc);case AccountingRangeRequest_LocalDate() when localDate != null:
return localDate(_that.localDate,_that.timezone);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String startUtc,  String endUtc)  utc,required TResult Function( String localDate,  String timezone)  localDate,}) {final _that = this;
switch (_that) {
case AccountingRangeRequest_Utc():
return utc(_that.startUtc,_that.endUtc);case AccountingRangeRequest_LocalDate():
return localDate(_that.localDate,_that.timezone);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String startUtc,  String endUtc)?  utc,TResult? Function( String localDate,  String timezone)?  localDate,}) {final _that = this;
switch (_that) {
case AccountingRangeRequest_Utc() when utc != null:
return utc(_that.startUtc,_that.endUtc);case AccountingRangeRequest_LocalDate() when localDate != null:
return localDate(_that.localDate,_that.timezone);case _:
  return null;

}
}

}

/// @nodoc


class AccountingRangeRequest_Utc extends AccountingRangeRequest {
  const AccountingRangeRequest_Utc({required this.startUtc, required this.endUtc}): super._();
  

 final  String startUtc;
 final  String endUtc;

/// Create a copy of AccountingRangeRequest
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingRangeRequest_UtcCopyWith<AccountingRangeRequest_Utc> get copyWith => _$AccountingRangeRequest_UtcCopyWithImpl<AccountingRangeRequest_Utc>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingRangeRequest_Utc&&(identical(other.startUtc, startUtc) || other.startUtc == startUtc)&&(identical(other.endUtc, endUtc) || other.endUtc == endUtc));
}


@override
int get hashCode => Object.hash(runtimeType,startUtc,endUtc);

@override
String toString() {
  return 'AccountingRangeRequest.utc(startUtc: $startUtc, endUtc: $endUtc)';
}


}

/// @nodoc
abstract mixin class $AccountingRangeRequest_UtcCopyWith<$Res> implements $AccountingRangeRequestCopyWith<$Res> {
  factory $AccountingRangeRequest_UtcCopyWith(AccountingRangeRequest_Utc value, $Res Function(AccountingRangeRequest_Utc) _then) = _$AccountingRangeRequest_UtcCopyWithImpl;
@useResult
$Res call({
 String startUtc, String endUtc
});




}
/// @nodoc
class _$AccountingRangeRequest_UtcCopyWithImpl<$Res>
    implements $AccountingRangeRequest_UtcCopyWith<$Res> {
  _$AccountingRangeRequest_UtcCopyWithImpl(this._self, this._then);

  final AccountingRangeRequest_Utc _self;
  final $Res Function(AccountingRangeRequest_Utc) _then;

/// Create a copy of AccountingRangeRequest
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? startUtc = null,Object? endUtc = null,}) {
  return _then(AccountingRangeRequest_Utc(
startUtc: null == startUtc ? _self.startUtc : startUtc // ignore: cast_nullable_to_non_nullable
as String,endUtc: null == endUtc ? _self.endUtc : endUtc // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AccountingRangeRequest_LocalDate extends AccountingRangeRequest {
  const AccountingRangeRequest_LocalDate({required this.localDate, required this.timezone}): super._();
  

 final  String localDate;
 final  String timezone;

/// Create a copy of AccountingRangeRequest
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AccountingRangeRequest_LocalDateCopyWith<AccountingRangeRequest_LocalDate> get copyWith => _$AccountingRangeRequest_LocalDateCopyWithImpl<AccountingRangeRequest_LocalDate>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AccountingRangeRequest_LocalDate&&(identical(other.localDate, localDate) || other.localDate == localDate)&&(identical(other.timezone, timezone) || other.timezone == timezone));
}


@override
int get hashCode => Object.hash(runtimeType,localDate,timezone);

@override
String toString() {
  return 'AccountingRangeRequest.localDate(localDate: $localDate, timezone: $timezone)';
}


}

/// @nodoc
abstract mixin class $AccountingRangeRequest_LocalDateCopyWith<$Res> implements $AccountingRangeRequestCopyWith<$Res> {
  factory $AccountingRangeRequest_LocalDateCopyWith(AccountingRangeRequest_LocalDate value, $Res Function(AccountingRangeRequest_LocalDate) _then) = _$AccountingRangeRequest_LocalDateCopyWithImpl;
@useResult
$Res call({
 String localDate, String timezone
});




}
/// @nodoc
class _$AccountingRangeRequest_LocalDateCopyWithImpl<$Res>
    implements $AccountingRangeRequest_LocalDateCopyWith<$Res> {
  _$AccountingRangeRequest_LocalDateCopyWithImpl(this._self, this._then);

  final AccountingRangeRequest_LocalDate _self;
  final $Res Function(AccountingRangeRequest_LocalDate) _then;

/// Create a copy of AccountingRangeRequest
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? localDate = null,Object? timezone = null,}) {
  return _then(AccountingRangeRequest_LocalDate(
localDate: null == localDate ? _self.localDate : localDate // ignore: cast_nullable_to_non_nullable
as String,timezone: null == timezone ? _self.timezone : timezone // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
