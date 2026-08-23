// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'service.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$HostDeclarativeV1NodeDto {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HostDeclarativeV1NodeDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'HostDeclarativeV1NodeDto()';
}


}

/// @nodoc
class $HostDeclarativeV1NodeDtoCopyWith<$Res>  {
$HostDeclarativeV1NodeDtoCopyWith(HostDeclarativeV1NodeDto _, $Res Function(HostDeclarativeV1NodeDto) __);
}


/// Adds pattern-matching-related methods to [HostDeclarativeV1NodeDto].
extension HostDeclarativeV1NodeDtoPatterns on HostDeclarativeV1NodeDto {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( HostDeclarativeV1NodeDto_Text value)?  text,TResult Function( HostDeclarativeV1NodeDto_Metric value)?  metric,TResult Function( HostDeclarativeV1NodeDto_Stack value)?  stack,TResult Function( HostDeclarativeV1NodeDto_List value)?  list,required TResult orElse(),}){
final _that = this;
switch (_that) {
case HostDeclarativeV1NodeDto_Text() when text != null:
return text(_that);case HostDeclarativeV1NodeDto_Metric() when metric != null:
return metric(_that);case HostDeclarativeV1NodeDto_Stack() when stack != null:
return stack(_that);case HostDeclarativeV1NodeDto_List() when list != null:
return list(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( HostDeclarativeV1NodeDto_Text value)  text,required TResult Function( HostDeclarativeV1NodeDto_Metric value)  metric,required TResult Function( HostDeclarativeV1NodeDto_Stack value)  stack,required TResult Function( HostDeclarativeV1NodeDto_List value)  list,}){
final _that = this;
switch (_that) {
case HostDeclarativeV1NodeDto_Text():
return text(_that);case HostDeclarativeV1NodeDto_Metric():
return metric(_that);case HostDeclarativeV1NodeDto_Stack():
return stack(_that);case HostDeclarativeV1NodeDto_List():
return list(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( HostDeclarativeV1NodeDto_Text value)?  text,TResult? Function( HostDeclarativeV1NodeDto_Metric value)?  metric,TResult? Function( HostDeclarativeV1NodeDto_Stack value)?  stack,TResult? Function( HostDeclarativeV1NodeDto_List value)?  list,}){
final _that = this;
switch (_that) {
case HostDeclarativeV1NodeDto_Text() when text != null:
return text(_that);case HostDeclarativeV1NodeDto_Metric() when metric != null:
return metric(_that);case HostDeclarativeV1NodeDto_Stack() when stack != null:
return stack(_that);case HostDeclarativeV1NodeDto_List() when list != null:
return list(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String text)?  text,TResult Function( String label,  String value)?  metric,TResult Function( List<HostDeclarativeV1NodeDto> children)?  stack,TResult Function( List<String> items)?  list,required TResult orElse(),}) {final _that = this;
switch (_that) {
case HostDeclarativeV1NodeDto_Text() when text != null:
return text(_that.text);case HostDeclarativeV1NodeDto_Metric() when metric != null:
return metric(_that.label,_that.value);case HostDeclarativeV1NodeDto_Stack() when stack != null:
return stack(_that.children);case HostDeclarativeV1NodeDto_List() when list != null:
return list(_that.items);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String text)  text,required TResult Function( String label,  String value)  metric,required TResult Function( List<HostDeclarativeV1NodeDto> children)  stack,required TResult Function( List<String> items)  list,}) {final _that = this;
switch (_that) {
case HostDeclarativeV1NodeDto_Text():
return text(_that.text);case HostDeclarativeV1NodeDto_Metric():
return metric(_that.label,_that.value);case HostDeclarativeV1NodeDto_Stack():
return stack(_that.children);case HostDeclarativeV1NodeDto_List():
return list(_that.items);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String text)?  text,TResult? Function( String label,  String value)?  metric,TResult? Function( List<HostDeclarativeV1NodeDto> children)?  stack,TResult? Function( List<String> items)?  list,}) {final _that = this;
switch (_that) {
case HostDeclarativeV1NodeDto_Text() when text != null:
return text(_that.text);case HostDeclarativeV1NodeDto_Metric() when metric != null:
return metric(_that.label,_that.value);case HostDeclarativeV1NodeDto_Stack() when stack != null:
return stack(_that.children);case HostDeclarativeV1NodeDto_List() when list != null:
return list(_that.items);case _:
  return null;

}
}

}

/// @nodoc


class HostDeclarativeV1NodeDto_Text extends HostDeclarativeV1NodeDto {
  const HostDeclarativeV1NodeDto_Text({required this.text}): super._();


 final  String text;

/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HostDeclarativeV1NodeDto_TextCopyWith<HostDeclarativeV1NodeDto_Text> get copyWith => _$HostDeclarativeV1NodeDto_TextCopyWithImpl<HostDeclarativeV1NodeDto_Text>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HostDeclarativeV1NodeDto_Text&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'HostDeclarativeV1NodeDto.text(text: $text)';
}


}

/// @nodoc
abstract mixin class $HostDeclarativeV1NodeDto_TextCopyWith<$Res> implements $HostDeclarativeV1NodeDtoCopyWith<$Res> {
  factory $HostDeclarativeV1NodeDto_TextCopyWith(HostDeclarativeV1NodeDto_Text value, $Res Function(HostDeclarativeV1NodeDto_Text) _then) = _$HostDeclarativeV1NodeDto_TextCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$HostDeclarativeV1NodeDto_TextCopyWithImpl<$Res>
    implements $HostDeclarativeV1NodeDto_TextCopyWith<$Res> {
  _$HostDeclarativeV1NodeDto_TextCopyWithImpl(this._self, this._then);

  final HostDeclarativeV1NodeDto_Text _self;
  final $Res Function(HostDeclarativeV1NodeDto_Text) _then;

/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(HostDeclarativeV1NodeDto_Text(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class HostDeclarativeV1NodeDto_Metric extends HostDeclarativeV1NodeDto {
  const HostDeclarativeV1NodeDto_Metric({required this.label, required this.value}): super._();


 final  String label;
 final  String value;

/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HostDeclarativeV1NodeDto_MetricCopyWith<HostDeclarativeV1NodeDto_Metric> get copyWith => _$HostDeclarativeV1NodeDto_MetricCopyWithImpl<HostDeclarativeV1NodeDto_Metric>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HostDeclarativeV1NodeDto_Metric&&(identical(other.label, label) || other.label == label)&&(identical(other.value, value) || other.value == value));
}


@override
int get hashCode => Object.hash(runtimeType,label,value);

@override
String toString() {
  return 'HostDeclarativeV1NodeDto.metric(label: $label, value: $value)';
}


}

/// @nodoc
abstract mixin class $HostDeclarativeV1NodeDto_MetricCopyWith<$Res> implements $HostDeclarativeV1NodeDtoCopyWith<$Res> {
  factory $HostDeclarativeV1NodeDto_MetricCopyWith(HostDeclarativeV1NodeDto_Metric value, $Res Function(HostDeclarativeV1NodeDto_Metric) _then) = _$HostDeclarativeV1NodeDto_MetricCopyWithImpl;
@useResult
$Res call({
 String label, String value
});




}
/// @nodoc
class _$HostDeclarativeV1NodeDto_MetricCopyWithImpl<$Res>
    implements $HostDeclarativeV1NodeDto_MetricCopyWith<$Res> {
  _$HostDeclarativeV1NodeDto_MetricCopyWithImpl(this._self, this._then);

  final HostDeclarativeV1NodeDto_Metric _self;
  final $Res Function(HostDeclarativeV1NodeDto_Metric) _then;

/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? label = null,Object? value = null,}) {
  return _then(HostDeclarativeV1NodeDto_Metric(
label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class HostDeclarativeV1NodeDto_Stack extends HostDeclarativeV1NodeDto {
  const HostDeclarativeV1NodeDto_Stack({required final  List<HostDeclarativeV1NodeDto> children}): _children = children,super._();


 final  List<HostDeclarativeV1NodeDto> _children;
 List<HostDeclarativeV1NodeDto> get children {
  if (_children is EqualUnmodifiableListView) return _children;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_children);
}


/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HostDeclarativeV1NodeDto_StackCopyWith<HostDeclarativeV1NodeDto_Stack> get copyWith => _$HostDeclarativeV1NodeDto_StackCopyWithImpl<HostDeclarativeV1NodeDto_Stack>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HostDeclarativeV1NodeDto_Stack&&const DeepCollectionEquality().equals(other._children, _children));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_children));

@override
String toString() {
  return 'HostDeclarativeV1NodeDto.stack(children: $children)';
}


}

/// @nodoc
abstract mixin class $HostDeclarativeV1NodeDto_StackCopyWith<$Res> implements $HostDeclarativeV1NodeDtoCopyWith<$Res> {
  factory $HostDeclarativeV1NodeDto_StackCopyWith(HostDeclarativeV1NodeDto_Stack value, $Res Function(HostDeclarativeV1NodeDto_Stack) _then) = _$HostDeclarativeV1NodeDto_StackCopyWithImpl;
@useResult
$Res call({
 List<HostDeclarativeV1NodeDto> children
});




}
/// @nodoc
class _$HostDeclarativeV1NodeDto_StackCopyWithImpl<$Res>
    implements $HostDeclarativeV1NodeDto_StackCopyWith<$Res> {
  _$HostDeclarativeV1NodeDto_StackCopyWithImpl(this._self, this._then);

  final HostDeclarativeV1NodeDto_Stack _self;
  final $Res Function(HostDeclarativeV1NodeDto_Stack) _then;

/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? children = null,}) {
  return _then(HostDeclarativeV1NodeDto_Stack(
children: null == children ? _self._children : children // ignore: cast_nullable_to_non_nullable
as List<HostDeclarativeV1NodeDto>,
  ));
}


}

/// @nodoc


class HostDeclarativeV1NodeDto_List extends HostDeclarativeV1NodeDto {
  const HostDeclarativeV1NodeDto_List({required final  List<String> items}): _items = items,super._();


 final  List<String> _items;
 List<String> get items {
  if (_items is EqualUnmodifiableListView) return _items;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_items);
}


/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HostDeclarativeV1NodeDto_ListCopyWith<HostDeclarativeV1NodeDto_List> get copyWith => _$HostDeclarativeV1NodeDto_ListCopyWithImpl<HostDeclarativeV1NodeDto_List>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HostDeclarativeV1NodeDto_List&&const DeepCollectionEquality().equals(other._items, _items));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_items));

@override
String toString() {
  return 'HostDeclarativeV1NodeDto.list(items: $items)';
}


}

/// @nodoc
abstract mixin class $HostDeclarativeV1NodeDto_ListCopyWith<$Res> implements $HostDeclarativeV1NodeDtoCopyWith<$Res> {
  factory $HostDeclarativeV1NodeDto_ListCopyWith(HostDeclarativeV1NodeDto_List value, $Res Function(HostDeclarativeV1NodeDto_List) _then) = _$HostDeclarativeV1NodeDto_ListCopyWithImpl;
@useResult
$Res call({
 List<String> items
});




}
/// @nodoc
class _$HostDeclarativeV1NodeDto_ListCopyWithImpl<$Res>
    implements $HostDeclarativeV1NodeDto_ListCopyWith<$Res> {
  _$HostDeclarativeV1NodeDto_ListCopyWithImpl(this._self, this._then);

  final HostDeclarativeV1NodeDto_List _self;
  final $Res Function(HostDeclarativeV1NodeDto_List) _then;

/// Create a copy of HostDeclarativeV1NodeDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? items = null,}) {
  return _then(HostDeclarativeV1NodeDto_List(
items: null == items ? _self._items : items // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

// dart format on
