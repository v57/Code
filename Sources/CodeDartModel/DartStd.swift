import Foundation

/// A hand-written stub of the `dart:` libraries most code uses, read when no Dart SDK is on disk (see `DartLayout`). It
/// is not the Dart SDK: the declarations are written from the SDK's API (Dart 3.x), without bodies, documentation or
/// the members few programs use. A place in it is named `dart:<library>/<Owner>.<member>` either way (see
/// `DartModel.place(of:)`), so answers read the same with the SDK on disk.
enum DartStd {
  static let files: [String: String] = [
    "core.dart": core, "async.dart": async, "convert.dart": convert, "io.dart": io, "typed_data.dart": typedData, "math.dart": math,
    "developer.dart": developer, "isolate.dart": isolate, "collection.dart": collection, "ffi.dart": ffi,
  ]

  static let header = "// Code's hand-written stub of the Dart SDK library (not the SDK itself): the declarations most code uses.\n"

  static let core = header + #"""
    library dart.core;

    import 'dart:collection';
    export 'dart:async' show Future, Stream;

    class Object {
      const Object();
      external bool operator ==(Object other);
      external int get hashCode;
      external String toString();
      external dynamic noSuchMethod(Invocation invocation);
      external Type get runtimeType;
      static int hash(Object? object1, Object? object2, [Object? object3, Object? object4, Object? object5, Object? object6]);
      static int hashAll(Iterable<Object?> objects);
      static int hashAllUnordered(Iterable<Object?> objects);
    }
    final class Null {
      external int get hashCode;
      String toString();
    }
    final class bool {
      external const factory bool.fromEnvironment(String name, {bool defaultValue = false});
      external const factory bool.hasEnvironment(String name);
      external int get hashCode;
      bool operator &(bool other);
      bool operator |(bool other);
      bool operator ^(bool other);
      String toString();
      external static bool parse(String source, {bool caseSensitive = true});
      external static bool? tryParse(String source, {bool caseSensitive = true});
    }
    abstract interface class Comparable<T> {
      int compareTo(T other);
      static int compare(Comparable a, Comparable b);
    }
    typedef Comparator<T> = int Function(T a, T b);
    sealed class num implements Comparable<num> {
      bool operator ==(Object other);
      int get hashCode;
      int compareTo(num other);
      num operator +(num other);
      num operator -(num other);
      num operator *(num other);
      num operator %(num other);
      double operator /(num other);
      int operator ~/(num other);
      num operator -();
      num remainder(num other);
      bool operator <(num other);
      bool operator <=(num other);
      bool operator >(num other);
      bool operator >=(num other);
      bool get isNaN;
      bool get isNegative;
      bool get isInfinite;
      bool get isFinite;
      num abs();
      num get sign;
      int round();
      int floor();
      int ceil();
      int truncate();
      double roundToDouble();
      double floorToDouble();
      double ceilToDouble();
      double truncateToDouble();
      num clamp(num lowerLimit, num upperLimit);
      int toInt();
      double toDouble();
      String toStringAsFixed(int fractionDigits);
      String toStringAsExponential([int? fractionDigits]);
      String toStringAsPrecision(int precision);
      String toString();
      static num parse(String input, [num onError(String input)?]);
      static num? tryParse(String input);
    }
    abstract final class int extends num {
      external const factory int.fromEnvironment(String name, {int defaultValue = 0});
      int operator &(int other);
      int operator |(int other);
      int operator ^(int other);
      int operator ~();
      int operator <<(int shiftAmount);
      int operator >>(int shiftAmount);
      int operator >>>(int shiftAmount);
      int modPow(int exponent, int modulus);
      int modInverse(int modulus);
      int gcd(int other);
      bool get isEven;
      bool get isOdd;
      int get bitLength;
      int toUnsigned(int width);
      int toSigned(int width);
      int operator -();
      int abs();
      int get sign;
      int round();
      int floor();
      int ceil();
      int truncate();
      double roundToDouble();
      double floorToDouble();
      double ceilToDouble();
      double truncateToDouble();
      String toString();
      String toRadixString(int radix);
      external static int parse(String source, {int? radix});
      external static int? tryParse(String source, {int? radix});
    }
    abstract final class double extends num {
      static const double nan = 0.0 / 0.0;
      static const double infinity = 1.0 / 0.0;
      static const double negativeInfinity = -infinity;
      static const double minPositive = 5e-324;
      static const double maxFinite = 1.7976931348623157e+308;
      double remainder(num other);
      double operator +(num other);
      double operator -(num other);
      double operator *(num other);
      double operator %(num other);
      double operator /(num other);
      int operator ~/(num other);
      double operator -();
      double abs();
      double get sign;
      int round();
      int floor();
      int ceil();
      int truncate();
      double roundToDouble();
      double floorToDouble();
      double ceilToDouble();
      double truncateToDouble();
      String toString();
      external static double parse(String source, [double onError(String source)?]);
      external static double? tryParse(String source);
    }
    abstract final class BigInt implements Comparable<BigInt> {
      external static BigInt get zero;
      external static BigInt get one;
      external static BigInt get two;
      external static BigInt parse(String source, {int? radix});
      external static BigInt? tryParse(String source, {int? radix});
      external factory BigInt.from(num value);
      BigInt abs();
      BigInt operator -();
      BigInt operator +(BigInt other);
      BigInt operator -(BigInt other);
      BigInt operator *(BigInt other);
      double operator /(BigInt other);
      BigInt operator ~/(BigInt other);
      BigInt operator %(BigInt other);
      BigInt remainder(BigInt other);
      BigInt operator <<(int shiftAmount);
      BigInt operator >>(int shiftAmount);
      BigInt operator &(BigInt other);
      BigInt operator |(BigInt other);
      BigInt operator ^(BigInt other);
      BigInt operator ~();
      bool operator <(BigInt other);
      bool operator <=(BigInt other);
      bool operator >(BigInt other);
      bool operator >=(BigInt other);
      int compareTo(BigInt other);
      int get bitLength;
      int get sign;
      bool get isEven;
      bool get isOdd;
      bool get isNegative;
      BigInt pow(int exponent);
      BigInt modPow(BigInt exponent, BigInt modulus);
      BigInt modInverse(BigInt modulus);
      BigInt gcd(BigInt other);
      BigInt toUnsigned(int width);
      BigInt toSigned(int width);
      bool get isValidInt;
      int toInt();
      double toDouble();
      String toString();
      String toRadixString(int radix);
    }
    abstract interface class Pattern {
      Iterable<Match> allMatches(String string, [int start = 0]);
      Match? matchAsPrefix(String string, [int start = 0]);
    }
    abstract interface class Match {
      int get start;
      int get end;
      String? group(int group);
      String? operator [](int group);
      List<String?> groups(List<int> groupIndices);
      int get groupCount;
      String get input;
      Pattern get pattern;
    }
    abstract interface class RegExp implements Pattern {
      external factory RegExp(String source, {bool multiLine = false, bool caseSensitive = true, bool unicode = false, bool dotAll = false});
      external static String escape(String text);
      RegExpMatch? firstMatch(String input);
      Iterable<RegExpMatch> allMatches(String input, [int start = 0]);
      bool hasMatch(String input);
      String? stringMatch(String input);
      String get pattern;
      bool get isMultiLine;
      bool get isCaseSensitive;
      bool get isUnicode;
      bool get isDotAll;
    }
    abstract interface class RegExpMatch implements Match {
      RegExp get pattern;
      String? namedGroup(String name);
      Iterable<String> get groupNames;
    }
    abstract final class String implements Comparable<String>, Pattern {
      external factory String.fromCharCodes(Iterable<int> charCodes, [int start = 0, int? end]);
      external factory String.fromCharCode(int charCode);
      external const factory String.fromEnvironment(String name, {String defaultValue = ""});
      String operator [](int index);
      int codeUnitAt(int index);
      int get length;
      int get hashCode;
      bool operator ==(Object other);
      int compareTo(String other);
      bool endsWith(String other);
      bool startsWith(Pattern pattern, [int index = 0]);
      int indexOf(Pattern pattern, [int start = 0]);
      int lastIndexOf(Pattern pattern, [int? start]);
      bool get isEmpty;
      bool get isNotEmpty;
      String operator +(String other);
      String substring(int start, [int? end]);
      String trim();
      String trimLeft();
      String trimRight();
      String operator *(int times);
      String padLeft(int width, [String padding = ' ']);
      String padRight(int width, [String padding = ' ']);
      bool contains(Pattern other, [int startIndex = 0]);
      String replaceFirst(Pattern from, String to, [int startIndex = 0]);
      String replaceFirstMapped(Pattern from, String replace(Match match), [int startIndex = 0]);
      String replaceAll(Pattern from, String replace);
      String replaceAllMapped(Pattern from, String replace(Match match));
      String replaceRange(int start, int? end, String replacement);
      List<String> split(Pattern pattern);
      String splitMapJoin(Pattern pattern, {String onMatch(Match match)?, String onNonMatch(String nonMatch)?});
      List<int> get codeUnits;
      Runes get runes;
      String toLowerCase();
      String toUpperCase();
    }
    final class Runes extends Iterable<int> {
      final String string;
      Runes(this.string);
    }
    abstract interface class StringSink {
      void write(Object? object);
      void writeAll(Iterable<dynamic> objects, [String separator = ""]);
      void writeln([Object? object = ""]);
      void writeCharCode(int charCode);
    }
    final class StringBuffer implements StringSink {
      external StringBuffer([Object content = ""]);
      int get length;
      bool get isEmpty;
      bool get isNotEmpty;
      external void write(Object? object);
      external void writeCharCode(int charCode);
      external void writeAll(Iterable<dynamic> objects, [String separator = ""]);
      external void writeln([Object? obj = ""]);
      external void clear();
      external String toString();
    }
    abstract interface class Iterator<E> {
      bool moveNext();
      E get current;
    }
    abstract mixin class Iterable<E> {
      const Iterable();
      factory Iterable.generate(int count, [E generator(int index)?]);
      const factory Iterable.empty() = EmptyIterable<E>;
      static Iterable<T> castFrom<S, T>(Iterable<S> source);
      Iterator<E> get iterator;
      Iterable<R> cast<R>();
      Iterable<E> followedBy(Iterable<E> other);
      Iterable<T> map<T>(T toElement(E e));
      Iterable<E> where(bool test(E element));
      Iterable<T> whereType<T>();
      Iterable<T> expand<T>(Iterable<T> toElements(E element));
      bool contains(Object? element);
      void forEach(void action(E element));
      E reduce(E combine(E value, E element));
      T fold<T>(T initialValue, T combine(T previousValue, E element));
      bool every(bool test(E element));
      String join([String separator = ""]);
      bool any(bool test(E element));
      List<E> toList({bool growable = true});
      Set<E> toSet();
      int get length;
      bool get isEmpty;
      bool get isNotEmpty;
      Iterable<E> take(int count);
      Iterable<E> takeWhile(bool test(E value));
      Iterable<E> skip(int count);
      Iterable<E> skipWhile(bool test(E value));
      E get first;
      E get last;
      E get single;
      E firstWhere(bool test(E element), {E orElse()?});
      E lastWhere(bool test(E element), {E orElse()?});
      E singleWhere(bool test(E element), {E orElse()?});
      E elementAt(int index);
      String toString();
      static String iterableToShortString(Iterable iterable, [String leftDelimiter = '(', String rightDelimiter = ')']);
      static String iterableToFullString(Iterable iterable, [String leftDelimiter = '(', String rightDelimiter = ')']);
    }
    extension IterableExtensions<T> on Iterable<T> {
      Iterable<(int, T)> get indexed;
      T? get firstOrNull;
      T? get lastOrNull;
      T? get singleOrNull;
      T? elementAtOrNull(int index);
    }
    extension NullableIterableExtensions<T extends Object> on Iterable<T?> {
      Iterable<T> get nonNulls;
    }
    abstract interface class BidirectionalIterator<E> implements Iterator<E> {
      bool movePrevious();
    }
    abstract interface class List<E> implements Iterable<E> {
      external factory List.filled(int length, E fill, {bool growable = false});
      external factory List.empty({bool growable = false});
      external factory List.from(Iterable elements, {bool growable = true});
      external factory List.of(Iterable<E> elements, {bool growable = true});
      external factory List.generate(int length, E generator(int index), {bool growable = true});
      external factory List.unmodifiable(Iterable elements);
      static List<T> castFrom<S, T>(List<S> source);
      static void copyRange<T>(List<T> target, int at, List<T> source, [int? start, int? end]);
      static void writeIterable<T>(List<T> target, int at, Iterable<T> source);
      List<R> cast<R>();
      E operator [](int index);
      void operator []=(int index, E value);
      void set first(E value);
      void set last(E value);
      int get length;
      set length(int newLength);
      void add(E value);
      void addAll(Iterable<E> iterable);
      Iterable<E> get reversed;
      void sort([int compare(E a, E b)?]);
      void shuffle([Random? random]);
      int indexOf(E element, [int start = 0]);
      int indexWhere(bool test(E element), [int start = 0]);
      int lastIndexWhere(bool test(E element), [int? start]);
      int lastIndexOf(E element, [int? start]);
      void clear();
      void insert(int index, E element);
      void insertAll(int index, Iterable<E> iterable);
      void setAll(int index, Iterable<E> iterable);
      bool remove(Object? value);
      E removeAt(int index);
      E removeLast();
      void removeWhere(bool test(E element));
      void retainWhere(bool test(E element));
      List<E> operator +(List<E> other);
      List<E> sublist(int start, [int? end]);
      Iterable<E> getRange(int start, int end);
      void setRange(int start, int end, Iterable<E> iterable, [int skipCount = 0]);
      void removeRange(int start, int end);
      void fillRange(int start, int end, [E? fillValue]);
      void replaceRange(int start, int end, Iterable<E> replacements);
      Map<int, E> asMap();
      bool operator ==(Object other);
    }
    abstract interface class Set<E> implements Iterable<E> {
      factory Set() = LinkedHashSet<E>;
      factory Set.identity() = LinkedHashSet<E>.identity;
      factory Set.from(Iterable elements) = LinkedHashSet<E>.from;
      factory Set.of(Iterable<E> elements) = LinkedHashSet<E>.of;
      factory Set.unmodifiable(Iterable<E> elements);
      static Set<T> castFrom<S, T>(Set<S> source, {Set<R> Function<R>()? newSet});
      Set<R> cast<R>();
      Iterator<E> get iterator;
      bool contains(Object? value);
      bool add(E value);
      void addAll(Iterable<E> elements);
      bool remove(Object? value);
      E? lookup(Object? object);
      void removeAll(Iterable<Object?> elements);
      void retainAll(Iterable<Object?> elements);
      void removeWhere(bool test(E element));
      void retainWhere(bool test(E element));
      bool containsAll(Iterable<Object?> other);
      Set<E> intersection(Set<Object?> other);
      Set<E> union(Set<E> other);
      Set<E> difference(Set<Object?> other);
      void clear();
      Set<E> toSet();
    }
    abstract interface class Map<K, V> {
      external factory Map();
      factory Map.from(Map other) = LinkedHashMap<K, V>.from;
      factory Map.of(Map<K, V> other) = LinkedHashMap<K, V>.of;
      external factory Map.unmodifiable(Map<dynamic, dynamic> other);
      factory Map.identity() = LinkedHashMap<K, V>.identity;
      factory Map.fromIterable(Iterable iterable, {K key(dynamic element)?, V value(dynamic element)?}) = LinkedHashMap<K, V>.fromIterable;
      factory Map.fromIterables(Iterable<K> keys, Iterable<V> values) = LinkedHashMap<K, V>.fromIterables;
      factory Map.fromEntries(Iterable<MapEntry<K, V>> entries);
      static Map<K2, V2> castFrom<K, V, K2, V2>(Map<K, V> source);
      Map<RK, RV> cast<RK, RV>();
      bool containsValue(Object? value);
      bool containsKey(Object? key);
      V? operator [](Object? key);
      void operator []=(K key, V value);
      Iterable<MapEntry<K, V>> get entries;
      Map<K2, V2> map<K2, V2>(MapEntry<K2, V2> convert(K key, V value));
      void addEntries(Iterable<MapEntry<K, V>> newEntries);
      V update(K key, V update(V value), {V ifAbsent()?});
      void updateAll(V update(K key, V value));
      void removeWhere(bool test(K key, V value));
      V putIfAbsent(K key, V ifAbsent());
      void addAll(Map<K, V> other);
      V? remove(Object? key);
      void clear();
      void forEach(void action(K key, V value));
      Iterable<K> get keys;
      Iterable<V> get values;
      int get length;
      bool get isEmpty;
      bool get isNotEmpty;
    }
    final class MapEntry<K, V> {
      final K key;
      final V value;
      const factory MapEntry(K key, V value) = MapEntry<K, V>._;
      const MapEntry._(this.key, this.value);
      String toString();
    }
    abstract interface class Sink<T> {
      void add(T data);
      void close();
    }
    abstract final class Function {
      external static apply(Function function, List<dynamic>? positionalArguments, [Map<Symbol, dynamic>? namedArguments]);
      int get hashCode;
      bool operator ==(Object other);
    }
    abstract final class Record {
      Type get runtimeType;
      int get hashCode;
      bool operator ==(Object other);
      String toString();
    }
    abstract interface class Type {
      int get hashCode;
      bool operator ==(Object other);
      String toString();
    }
    abstract interface class Symbol {
      const factory Symbol(String name) = internal.Symbol;
      int get hashCode;
      bool operator ==(Object other);
    }
    abstract interface class Invocation {
      Symbol get memberName;
      List<Type> get typeArguments;
      List<dynamic> get positionalArguments;
      Map<Symbol, dynamic> get namedArguments;
      bool get isMethod;
      bool get isGetter;
      bool get isSetter;
    }
    abstract interface class Enum {
      int get index;
      static int compareByIndex<T extends Enum>(T value1, T value2);
      static int compareByName<T extends Enum>(T value1, T value2);
    }
    extension EnumName on Enum {
      String get name;
    }
    extension EnumByName<T extends Enum> on Iterable<T> {
      T byName(String name);
      Map<String, T> asNameMap();
    }
    class DateTime implements Comparable<DateTime> {
      static const int monday = 1;
      static const int tuesday = 2;
      static const int wednesday = 3;
      static const int thursday = 4;
      static const int friday = 5;
      static const int saturday = 6;
      static const int sunday = 7;
      static const int daysPerWeek = 7;
      static const int january = 1;
      static const int december = 12;
      static const int monthsPerYear = 12;
      final bool isUtc;
      DateTime(int year, [int month = 1, int day = 1, int hour = 0, int minute = 0, int second = 0, int millisecond = 0, int microsecond = 0]);
      DateTime.utc(int year, [int month = 1, int day = 1, int hour = 0, int minute = 0, int second = 0, int millisecond = 0, int microsecond = 0]);
      external DateTime.now();
      external DateTime.timestamp();
      external DateTime.fromMillisecondsSinceEpoch(int millisecondsSinceEpoch, {bool isUtc = false});
      external DateTime.fromMicrosecondsSinceEpoch(int microsecondsSinceEpoch, {bool isUtc = false});
      external static DateTime parse(String formattedString);
      external static DateTime? tryParse(String formattedString);
      external bool operator ==(Object other);
      external bool isBefore(DateTime other);
      external bool isAfter(DateTime other);
      external bool isAtSameMomentAs(DateTime other);
      external int compareTo(DateTime other);
      external int get hashCode;
      external DateTime toLocal();
      external DateTime toUtc();
      external String toString();
      external String toIso8601String();
      external DateTime add(Duration duration);
      external DateTime subtract(Duration duration);
      external Duration difference(DateTime other);
      external DateTime copyWith({int? year, int? month, int? day, int? hour, int? minute, int? second, int? millisecond, int? microsecond, bool? isUtc});
      external int get millisecondsSinceEpoch;
      external int get microsecondsSinceEpoch;
      external String get timeZoneName;
      external Duration get timeZoneOffset;
      external int get year;
      external int get month;
      external int get day;
      external int get hour;
      external int get minute;
      external int get second;
      external int get millisecond;
      external int get microsecond;
      external int get weekday;
    }
    class Duration implements Comparable<Duration> {
      static const int microsecondsPerMillisecond = 1000;
      static const int millisecondsPerSecond = 1000;
      static const int secondsPerMinute = 60;
      static const int minutesPerHour = 60;
      static const int hoursPerDay = 24;
      static const int microsecondsPerSecond = 1000000;
      static const int millisecondsPerMinute = 60000;
      static const int millisecondsPerHour = 3600000;
      static const int millisecondsPerDay = 86400000;
      static const Duration zero = Duration(seconds: 0);
      const Duration({int days = 0, int hours = 0, int minutes = 0, int seconds = 0, int milliseconds = 0, int microseconds = 0});
      Duration operator +(Duration other);
      Duration operator -(Duration other);
      Duration operator *(num factor);
      Duration operator ~/(int quotient);
      bool operator <(Duration other);
      bool operator >(Duration other);
      bool operator <=(Duration other);
      bool operator >=(Duration other);
      int get inDays;
      int get inHours;
      int get inMinutes;
      int get inSeconds;
      int get inMilliseconds;
      int get inMicroseconds;
      bool operator ==(Object other);
      int get hashCode;
      int compareTo(Duration other);
      String toString();
      bool get isNegative;
      Duration abs();
      Duration operator -();
    }
    final class Stopwatch {
      int get frequency;
      Stopwatch();
      void start();
      void stop();
      void reset();
      int get elapsedTicks;
      Duration get elapsed;
      int get elapsedMicroseconds;
      int get elapsedMilliseconds;
      bool get isRunning;
    }
    abstract interface class Uri {
      external static Uri get base;
      factory Uri({String? scheme, String? userInfo, String? host, int? port, String? path, Iterable<String>? pathSegments, String? query, Map<String, dynamic>? queryParameters, String? fragment});
      factory Uri.http(String authority, [String unencodedPath = "", Map<String, dynamic>? queryParameters]);
      factory Uri.https(String authority, [String unencodedPath = "", Map<String, dynamic>? queryParameters]);
      factory Uri.file(String path, {bool? windows});
      factory Uri.directory(String path, {bool? windows});
      factory Uri.dataFromString(String content, {String? mimeType, Encoding? encoding, Map<String, String>? parameters, bool base64 = false});
      String get scheme;
      String get authority;
      String get userInfo;
      String get host;
      int get port;
      String get path;
      String get query;
      String get fragment;
      List<String> get pathSegments;
      Map<String, String> get queryParameters;
      Map<String, List<String>> get queryParametersAll;
      bool get isAbsolute;
      bool get hasScheme;
      bool get hasAuthority;
      bool get hasPort;
      bool get hasQuery;
      bool get hasFragment;
      bool get hasEmptyPath;
      bool get hasAbsolutePath;
      String get origin;
      bool isScheme(String scheme);
      String toFilePath({bool? windows});
      UriData? get data;
      int get hashCode;
      bool operator ==(Object other);
      String toString();
      Uri replace({String? scheme, String? userInfo, String? host, int? port, String? path, Iterable<String>? pathSegments, String? query, Map<String, dynamic>? queryParameters, String? fragment});
      Uri removeFragment();
      Uri resolve(String reference);
      Uri resolveUri(Uri reference);
      Uri normalizePath();
      static Uri parse(String uri, [int start = 0, int? end]);
      static Uri? tryParse(String uri, [int start = 0, int? end]);
      static String encodeComponent(String component);
      static String encodeQueryComponent(String component, {Encoding encoding = utf8});
      static String decodeComponent(String encodedComponent);
      static String decodeQueryComponent(String encodedComponent, {Encoding encoding = utf8});
      static String encodeFull(String uri);
      static String decodeFull(String uri);
      static Map<String, String> splitQueryString(String query, {Encoding encoding = utf8});
    }
    final class UriData {
      String get mimeType;
      String get charset;
      bool get isBase64;
      String get contentText;
      Uint8List contentAsBytes();
      String contentAsString({Encoding? encoding});
    }
    abstract interface class Exception {
      factory Exception([var message]);
    }
    class FormatException implements Exception {
      final String message;
      final dynamic source;
      final int? offset;
      const FormatException([this.message = "", this.source, this.offset]);
      String toString();
    }
    class IntegerDivisionByZeroException implements Exception, UnsupportedError {
      const IntegerDivisionByZeroException();
    }
    class Error {
      Error();
      external StackTrace? get stackTrace;
      static String safeToString(Object? object);
      external static Never throwWithStackTrace(Object error, StackTrace stackTrace);
    }
    class AssertionError extends Error {
      final Object? message;
      AssertionError([this.message]);
    }
    class TypeError extends Error {}
    class ArgumentError extends Error {
      final bool _hasValue;
      final dynamic invalidValue;
      final String? name;
      final dynamic message;
      ArgumentError([this.message, this.name]);
      ArgumentError.value(value, [this.name, this.message]);
      ArgumentError.notNull([this.name]);
      static T checkNotNull<T>(T? argument, [String? name]);
      String toString();
    }
    class RangeError extends ArgumentError {
      final num? start;
      final num? end;
      RangeError(var message);
      RangeError.value(num value, [String? name, String? message]);
      RangeError.range(num invalidValue, int? minValue, int? maxValue, [String? name, String? message]);
      factory RangeError.index(int index, dynamic indexable, [String? name, String? message, int? length]);
      static int checkValueInInterval(int value, int minValue, int maxValue, [String? name, String? message]);
      static int checkValidIndex(int index, dynamic indexable, [String? name, int? length, String? message]);
      static int checkValidRange(int start, int? end, int length, [String? startName, String? endName, String? message]);
      static int checkNotNegative(int value, [String? name, String? message]);
    }
    class IndexError extends ArgumentError implements RangeError {
      final Object? indexable;
      final int length;
      IndexError.withLength(int invalidValue, this.length, {this.indexable, String? name, String? message});
    }
    class NoSuchMethodError extends Error {
      external factory NoSuchMethodError.withInvocation(Object? receiver, Invocation invocation);
    }
    class UnsupportedError extends Error {
      final String? message;
      UnsupportedError(String this.message);
    }
    class UnimplementedError extends Error implements UnsupportedError {
      final String? message;
      UnimplementedError([this.message]);
    }
    class StateError extends Error {
      final String message;
      StateError(this.message);
    }
    class ConcurrentModificationError extends Error {
      final Object? modifiedObject;
      ConcurrentModificationError([this.modifiedObject]);
    }
    final class OutOfMemoryError implements Error {
      const OutOfMemoryError();
    }
    final class StackOverflowError implements Error {
      const StackOverflowError();
    }
    abstract interface class StackTrace {
      static const StackTrace empty = _StringStackTrace("");
      factory StackTrace.fromString(String stackTraceString) = _StringStackTrace;
      external static StackTrace get current;
      String toString();
    }
    final class Expando<T extends Object> {
      final String? name;
      external Expando([String? name]);
      external T? operator [](Object object);
      external void operator []=(Object object, T? value);
    }
    final class WeakReference<T extends Object> {
      external factory WeakReference(T target);
      T? get target;
    }
    abstract final class Finalizer<T> {
      external factory Finalizer(void Function(T) callback);
      void attach(Object value, T finalizationToken, {Object? detach});
      void detach(Object detach);
    }
    class Deprecated {
      final String message;
      const Deprecated(String message);
    }
    const Deprecated deprecated = Deprecated("next release");
    const Object override = _Override();
    final class pragma {
      final String name;
      final Object? options;
      const pragma(this.name, [this.options]);
    }
    void print(Object? object);
    external bool identical(Object? a, Object? b);
    external int identityHashCode(Object? object);
    """#

  static let async = header + #"""
    library dart.async;

    abstract interface class Future<T> {
      factory Future(FutureOr<T> computation());
      factory Future.microtask(FutureOr<T> computation());
      factory Future.sync(FutureOr<T> computation());
      factory Future.value([FutureOr<T>? value]);
      factory Future.error(Object error, [StackTrace? stackTrace]);
      factory Future.delayed(Duration duration, [FutureOr<T> computation()?]);
      static Future<List<T>> wait<T>(Iterable<Future<T>> futures, {bool eagerError = false, void cleanUp(T successValue)?});
      static Future<T> any<T>(Iterable<Future<T>> futures);
      static Future<void> forEach<T>(Iterable<T> elements, FutureOr action(T element));
      static Future<void> doWhile(FutureOr<bool> action());
      Future<R> then<R>(FutureOr<R> onValue(T value), {Function? onError});
      Future<T> catchError(Function onError, {bool test(Object error)?});
      Future<T> whenComplete(FutureOr<void> action());
      Stream<T> asStream();
      Future<T> timeout(Duration timeLimit, {FutureOr<T> onTimeout()?});
    }
    extension FutureExtensions<T> on Future<T> {
      Future<T> onError<E extends Object>(FutureOr<T> handleError(E error, StackTrace stackTrace), {bool test(E error)?});
      void ignore();
    }
    extension FutureIterable<T> on Iterable<Future<T>> {
      Future<List<T>> get wait;
    }
    abstract final class FutureOr<T> {}
    void unawaited(Future<void>? future);
    abstract interface class Completer<T> {
      factory Completer();
      factory Completer.sync();
      Future<T> get future;
      void complete([FutureOr<T>? value]);
      void completeError(Object error, [StackTrace? stackTrace]);
      bool get isCompleted;
    }
    class TimeoutException implements Exception {
      final String? message;
      final Duration? duration;
      TimeoutException(this.message, [this.duration]);
      String toString();
    }
    abstract mixin class Stream<T> {
      const Stream();
      const factory Stream.empty({bool broadcast = true});
      factory Stream.value(T value);
      factory Stream.error(Object error, [StackTrace? stackTrace]);
      factory Stream.fromFuture(Future<T> future);
      factory Stream.fromFutures(Iterable<Future<T>> futures);
      factory Stream.fromIterable(Iterable<T> elements);
      factory Stream.multi(void Function(MultiStreamController<T>) onListen, {bool isBroadcast = false});
      factory Stream.periodic(Duration period, [T computation(int computationCount)?]);
      factory Stream.eventTransformed(Stream<dynamic> source, EventSink<dynamic> mapSink(EventSink<T> sink));
      bool get isBroadcast;
      Stream<T> asBroadcastStream({void onListen(StreamSubscription<T> subscription)?, void onCancel(StreamSubscription<T> subscription)?});
      StreamSubscription<T> listen(void onData(T event)?, {Function? onError, void onDone()?, bool? cancelOnError});
      Stream<T> where(bool test(T event));
      Stream<S> map<S>(S convert(T event));
      Stream<E> asyncMap<E>(FutureOr<E> convert(T event));
      Stream<E> asyncExpand<E>(Stream<E>? convert(T event));
      Stream<T> handleError(Function onError, {bool test(dynamic error)?});
      Stream<S> expand<S>(Iterable<S> convert(T element));
      Future pipe(StreamConsumer<T> streamConsumer);
      Stream<S> transform<S>(StreamTransformer<T, S> streamTransformer);
      Future<T> reduce(T combine(T previous, T element));
      Future<S> fold<S>(S initialValue, S combine(S previous, T element));
      Future<String> join([String separator = ""]);
      Future<bool> contains(Object? needle);
      Future<void> forEach(void action(T element));
      Future<bool> every(bool test(T element));
      Future<bool> any(bool test(T element));
      Future<int> get length;
      Future<bool> get isEmpty;
      Stream<R> cast<R>();
      Future<List<T>> toList();
      Future<Set<T>> toSet();
      Future<E> drain<E>([E? futureValue]);
      Stream<T> take(int count);
      Stream<T> takeWhile(bool test(T element));
      Stream<T> skip(int count);
      Stream<T> skipWhile(bool test(T element));
      Stream<T> distinct([bool equals(T previous, T next)?]);
      Future<T> get first;
      Future<T> get last;
      Future<T> get single;
      Future<T> firstWhere(bool test(T element), {T orElse()?});
      Future<T> lastWhere(bool test(T element), {T orElse()?});
      Future<T> singleWhere(bool test(T element), {T orElse()?});
      Future<T> elementAt(int index);
      Stream<T> timeout(Duration timeLimit, {void onTimeout(EventSink<T> sink)?});
    }
    abstract interface class StreamSubscription<T> {
      Future<void> cancel();
      void onData(void handleData(T data)?);
      void onError(Function? handleError);
      void onDone(void handleDone()?);
      void pause([Future<void>? resumeSignal]);
      void resume();
      bool get isPaused;
      Future<E> asFuture<E>([E? futureValue]);
    }
    abstract interface class EventSink<T> implements Sink<T> {
      void add(T event);
      void addError(Object error, [StackTrace? stackTrace]);
      void close();
    }
    abstract interface class StreamConsumer<S> {
      Future addStream(Stream<S> stream);
      Future close();
    }
    abstract interface class StreamSink<S> implements EventSink<S>, StreamConsumer<S> {
      Future close();
      Future get done;
    }
    abstract interface class StreamTransformer<S, T> {
      const factory StreamTransformer(StreamSubscription<T> onListen(Stream<S> stream, bool cancelOnError)) = _StreamSubscriptionTransformer<S, T>;
      factory StreamTransformer.fromHandlers({void handleData(S data, EventSink<T> sink)?, void handleError(Object error, StackTrace stackTrace, EventSink<T> sink)?, void handleDone(EventSink<T> sink)?});
      factory StreamTransformer.fromBind(Stream<T> Function(Stream<S>) bind);
      Stream<T> bind(Stream<S> stream);
      StreamTransformer<RS, RT> cast<RS, RT>();
    }
    abstract class StreamTransformerBase<S, T> implements StreamTransformer<S, T> {
      const StreamTransformerBase();
    }
    abstract interface class StreamIterator<T> {
      factory StreamIterator(Stream<T> stream);
      Future<bool> moveNext();
      T get current;
      Future cancel();
    }
    abstract interface class StreamController<T> implements StreamSink<T> {
      Stream<T> get stream;
      factory StreamController({void onListen()?, void onPause()?, void onResume()?, FutureOr<void> onCancel()?, bool sync = false});
      factory StreamController.broadcast({void onListen()?, void onCancel()?, bool sync = false});
      abstract void Function()? onListen;
      abstract void Function()? onPause;
      abstract void Function()? onResume;
      abstract FutureOr<void> Function()? onCancel;
      StreamSink<T> get sink;
      bool get isClosed;
      bool get isPaused;
      bool get hasListener;
      void add(T event);
      void addError(Object error, [StackTrace? stackTrace]);
      Future close();
      Future get done;
      Future addStream(Stream<T> source, {bool? cancelOnError});
    }
    abstract interface class MultiStreamController<T> implements StreamController<T> {
      void addSync(T value);
      void addErrorSync(Object error, [StackTrace? stackTrace]);
      void closeSync();
    }
    abstract interface class Timer {
      factory Timer(Duration duration, void callback());
      factory Timer.periodic(Duration duration, void callback(Timer timer));
      static void run(void callback());
      void cancel();
      int get tick;
      bool get isActive;
    }
    abstract final class Zone {
      static const Zone root = _rootZone;
      static Zone get current;
      Zone? get parent;
      Zone fork({ZoneSpecification? specification, Map<Object?, Object?>? zoneValues});
      R run<R>(R action());
      R runGuarded<R>(R action());
      void scheduleMicrotask(void callback());
      dynamic operator [](Object? key);
    }
    void scheduleMicrotask(void callback());
    R runZoned<R>(R body(), {Map<Object?, Object?>? zoneValues, ZoneSpecification? zoneSpecification, Function? onError});
    R? runZonedGuarded<R>(R body(), void onError(Object error, StackTrace stack), {Map<Object?, Object?>? zoneValues, ZoneSpecification? zoneSpecification});
    """#

  static let convert = header + #"""
    library dart.convert;

    import 'dart:async';
    import 'dart:typed_data';

    abstract mixin class Codec<S, T> {
      const Codec();
      T encode(S input);
      S decode(T encoded);
      Converter<S, T> get encoder;
      Converter<T, S> get decoder;
      Codec<S, R> fuse<R>(Codec<T, R> other);
      Codec<T, S> get inverted;
    }
    abstract class Converter<S, T> extends StreamTransformerBase<S, T> {
      const Converter();
      T convert(S input);
      Converter<S, TT> fuse<TT>(Converter<T, TT> other);
      Sink<S> startChunkedConversion(Sink<T> sink);
      Stream<T> bind(Stream<S> stream);
      Converter<RS, RT> cast<RS, RT>();
    }
    abstract class Encoding extends Codec<String, List<int>> {
      const Encoding();
      Converter<String, List<int>> get encoder;
      Converter<List<int>, String> get decoder;
      Future<String> decodeStream(Stream<List<int>> byteStream);
      String get name;
      static Encoding? getByName(String? name);
    }
    const JsonCodec json = JsonCodec();
    String jsonEncode(Object? object, {Object? toEncodable(Object? nonEncodable)?});
    dynamic jsonDecode(String source, {Object? reviver(Object? key, Object? value)?});
    final class JsonCodec extends Codec<Object?, String> {
      const JsonCodec({Object? reviver(Object? key, Object? value)?, Object? toEncodable(dynamic object)?});
      const JsonCodec.withReviver(dynamic reviver(Object? key, Object? value));
      dynamic decode(String source, {Object? reviver(Object? key, Object? value)?});
      String encode(Object? value, {Object? toEncodable(dynamic object)?});
      JsonEncoder get encoder;
      JsonDecoder get decoder;
    }
    class JsonEncoder extends Converter<Object?, String> {
      final String? indent;
      const JsonEncoder([Object? toEncodable(dynamic object)?]);
      const JsonEncoder.withIndent(this.indent, [Object? toEncodable(dynamic object)?]);
      String convert(Object? object);
    }
    class JsonDecoder extends Converter<String, Object?> {
      const JsonDecoder([Object? reviver(Object? key, Object? value)?]);
      dynamic convert(String input);
    }
    class JsonUnsupportedObjectError extends Error {
      final Object? unsupportedObject;
      final Object? cause;
      final String? partialResult;
      JsonUnsupportedObjectError(this.unsupportedObject, {this.cause, this.partialResult});
    }
    const Utf8Codec utf8 = Utf8Codec();
    final class Utf8Codec extends Encoding {
      const Utf8Codec({bool allowMalformed = false});
      String get name;
      String decode(List<int> codeUnits, {bool? allowMalformed});
      Uint8List encode(String input);
      Utf8Encoder get encoder;
      Utf8Decoder get decoder;
    }
    class Utf8Encoder extends Converter<String, List<int>> {
      const Utf8Encoder();
      Uint8List convert(String string, [int start = 0, int? end]);
    }
    class Utf8Decoder extends Converter<List<int>, String> {
      const Utf8Decoder({bool allowMalformed = false});
      String convert(List<int> codeUnits, [int start = 0, int? end]);
    }
    const AsciiCodec ascii = AsciiCodec();
    final class AsciiCodec extends Encoding {
      const AsciiCodec({bool allowInvalid = false});
      String get name;
      Uint8List encode(String source);
      String decode(List<int> bytes, {bool? allowInvalid});
    }
    const Latin1Codec latin1 = Latin1Codec();
    final class Latin1Codec extends Encoding {
      const Latin1Codec({bool allowInvalid = false});
      String get name;
      Uint8List encode(String source);
      String decode(List<int> bytes, {bool? allowInvalid});
    }
    const Base64Codec base64 = Base64Codec();
    const Base64Codec base64Url = Base64Codec.urlSafe();
    String base64Encode(List<int> bytes);
    String base64UrlEncode(List<int> bytes);
    Uint8List base64Decode(String source);
    final class Base64Codec extends Codec<List<int>, String> {
      const Base64Codec();
      const Base64Codec.urlSafe();
      Base64Encoder get encoder;
      Base64Decoder get decoder;
      Uint8List decode(String encoded);
      String normalize(String source, [int start = 0, int? end]);
    }
    final class Base64Encoder extends Converter<List<int>, String> {
      const Base64Encoder();
      const Base64Encoder.urlSafe();
      String convert(List<int> input);
    }
    final class Base64Decoder extends Converter<String, List<int>> {
      const Base64Decoder();
      Uint8List convert(String input, [int start = 0, int? end]);
    }
    class LineSplitter extends StreamTransformerBase<String, String> {
      const LineSplitter();
      static Iterable<String> split(String lines, [int start = 0, int? end]);
      List<String> convert(String data);
      Stream<String> bind(Stream<String> stream);
    }
    const HtmlEscape htmlEscape = HtmlEscape();
    final class HtmlEscape extends Converter<String, String> {
      const HtmlEscape([HtmlEscapeMode mode = HtmlEscapeMode.unknown]);
      String convert(String text);
    }
    """#

  static let io = header + #"""
    library dart.io;

    import 'dart:async';
    import 'dart:convert';
    import 'dart:typed_data';

    abstract class IOException implements Exception {}
    final class OSError implements Exception {
      final String message;
      final int errorCode;
      const OSError([this.message = "", this.errorCode = noErrorCode]);
    }
    class FileSystemException implements IOException {
      final String message;
      final String? path;
      final OSError? osError;
      const FileSystemException([this.message = "", this.path = "", this.osError]);
    }
    class PathNotFoundException extends FileSystemException {
      const PathNotFoundException(String path, OSError osError, [String message = ""]);
    }
    class SocketException implements IOException {
      final String message;
      final OSError? osError;
      final InternetAddress? address;
      final int? port;
      const SocketException(this.message, {this.osError, this.address, this.port});
    }
    class HttpException implements IOException {
      final String message;
      final Uri? uri;
      const HttpException(this.message, {this.uri});
    }
    class ProcessException implements IOException {
      final String executable;
      final List<String> arguments;
      final String message;
      final int errorCode;
      const ProcessException(this.executable, this.arguments, [this.message = "", this.errorCode = 0]);
    }
    class TlsException implements IOException {
      final String type;
      final String message;
      final OSError? osError;
      const TlsException([String message = "", OSError? osError]);
    }
    class HandshakeException extends TlsException {
      const HandshakeException([String message = "", OSError? osError]);
    }
    abstract class FileSystemEntity {
      String get path;
      Uri get uri;
      Future<bool> exists();
      bool existsSync();
      Future<FileSystemEntity> rename(String newPath);
      FileSystemEntity renameSync(String newPath);
      Future<String> resolveSymbolicLinks();
      String resolveSymbolicLinksSync();
      Future<FileStat> stat();
      FileStat statSync();
      Future<FileSystemEntity> delete({bool recursive = false});
      void deleteSync({bool recursive = false});
      Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false});
      bool get isAbsolute;
      FileSystemEntity get absolute;
      Directory get parent;
      static Future<bool> identical(String path1, String path2);
      static Future<FileSystemEntityType> type(String path, {bool followLinks = true});
      static FileSystemEntityType typeSync(String path, {bool followLinks = true});
      static Future<bool> isLink(String path);
      static Future<bool> isFile(String path);
      static Future<bool> isDirectory(String path);
      static bool isLinkSync(String path);
      static bool isFileSync(String path);
      static bool isDirectorySync(String path);
      static String parentOf(String path);
    }
    final class FileSystemEntityType {
      static const file = FileSystemEntityType._internalFile;
      static const directory = FileSystemEntityType._internalDirectory;
      static const link = FileSystemEntityType._internalLink;
      static const unixDomainSock = FileSystemEntityType._internalUnixDomainSock;
      static const pipe = FileSystemEntityType._internalPipe;
      static const notFound = FileSystemEntityType._internalNotFound;
    }
    class FileSystemEvent {
      static const int create = 1;
      static const int modify = 2;
      static const int delete = 4;
      static const int move = 8;
      static const int all = create | modify | delete | move;
      final int type;
      final String path;
      final bool isDirectory;
    }
    class FileStat {
      final DateTime changed;
      final DateTime modified;
      final DateTime accessed;
      final FileSystemEntityType type;
      final int mode;
      final int size;
      static Future<FileStat> stat(String path);
      static FileStat statSync(String path);
      String modeString();
    }
    final class FileMode {
      static const read = FileMode._internal(0);
      static const write = FileMode._internal(1);
      static const append = FileMode._internal(2);
      static const writeOnly = FileMode._internal(3);
      static const writeOnlyAppend = FileMode._internal(4);
    }
    abstract interface class File implements FileSystemEntity {
      factory File(String path);
      factory File.fromUri(Uri uri);
      factory File.fromRawPath(Uint8List rawPath);
      Future<File> create({bool recursive = false, bool exclusive = false});
      void createSync({bool recursive = false, bool exclusive = false});
      Future<File> rename(String newPath);
      File renameSync(String newPath);
      Future<File> copy(String newPath);
      File copySync(String newPath);
      Future<int> length();
      int lengthSync();
      File get absolute;
      Future<DateTime> lastAccessed();
      DateTime lastAccessedSync();
      Future setLastAccessed(DateTime time);
      Future<DateTime> lastModified();
      DateTime lastModifiedSync();
      Future setLastModified(DateTime time);
      void setLastModifiedSync(DateTime time);
      Future<RandomAccessFile> open({FileMode mode = FileMode.read});
      RandomAccessFile openSync({FileMode mode = FileMode.read});
      Stream<List<int>> openRead([int? start, int? end]);
      IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8});
      Future<Uint8List> readAsBytes();
      Uint8List readAsBytesSync();
      Future<String> readAsString({Encoding encoding = utf8});
      String readAsStringSync({Encoding encoding = utf8});
      Future<List<String>> readAsLines({Encoding encoding = utf8});
      List<String> readAsLinesSync({Encoding encoding = utf8});
      Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false});
      void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false});
      Future<File> writeAsString(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false});
      void writeAsStringSync(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false});
      String get path;
    }
    abstract interface class RandomAccessFile {
      Future<void> close();
      void closeSync();
      Future<int> readByte();
      int readByteSync();
      Future<Uint8List> read(int count);
      Uint8List readSync(int count);
      Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]);
      void writeFromSync(List<int> buffer, [int start = 0, int? end]);
      Future<int> position();
      int positionSync();
      Future<RandomAccessFile> setPosition(int position);
      void setPositionSync(int position);
      Future<int> length();
      int lengthSync();
      Future<RandomAccessFile> flush();
      void flushSync();
      String get path;
    }
    abstract interface class Directory implements FileSystemEntity {
      String get path;
      factory Directory(String path);
      factory Directory.fromUri(Uri uri);
      static Directory get current;
      static set current(path);
      static Directory get systemTemp;
      Uri get uri;
      Future<Directory> create({bool recursive = false});
      void createSync({bool recursive = false});
      Future<Directory> createTemp([String? prefix]);
      Directory createTempSync([String? prefix]);
      Future<String> resolveSymbolicLinks();
      Future<Directory> rename(String newPath);
      Directory renameSync(String newPath);
      Directory get absolute;
      Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true});
      List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true});
    }
    abstract interface class Link implements FileSystemEntity {
      factory Link(String path);
      Future<Link> create(String target, {bool recursive = false});
      void createSync(String target, {bool recursive = false});
      Future<String> target();
      String targetSync();
    }
    abstract interface class IOSink implements StreamSink<List<int>>, StringSink {
      factory IOSink(StreamConsumer<List<int>> target, {Encoding encoding = utf8});
      late Encoding encoding;
      void add(List<int> data);
      void write(Object? object);
      void writeAll(Iterable objects, [String separator = ""]);
      void writeln([Object? object = ""]);
      void writeCharCode(int charCode);
      void addError(error, [StackTrace? stackTrace]);
      Future addStream(Stream<List<int>> stream);
      Future flush();
      Future close();
      Future get done;
    }
    class Stdin extends Stream<List<int>> {
      String? readLineSync({Encoding encoding = systemEncoding, bool retainNewlines = false});
      int readByteSync();
      bool get echoMode;
      set echoMode(bool echoMode);
      bool get lineMode;
      set lineMode(bool lineMode);
      bool get hasTerminal;
      bool get supportsAnsiEscapes;
    }
    class Stdout extends _StdSink implements IOSink {
      bool get hasTerminal;
      int get terminalColumns;
      int get terminalLines;
      bool get supportsAnsiEscapes;
      IOSink get nonBlocking;
    }
    Stdin get stdin;
    Stdout get stdout;
    Stdout get stderr;
    Never exit(int code);
    set exitCode(int code);
    int get exitCode;
    int get pid;
    void sleep(Duration duration);
    const SystemEncoding systemEncoding = SystemEncoding();
    final class SystemEncoding extends Encoding {
      const SystemEncoding();
      String get name;
      List<int> encode(String input);
      String decode(List<int> encoded);
    }
    abstract final class Platform {
      static int get numberOfProcessors;
      static String get pathSeparator;
      static String get localeName;
      static String get operatingSystem;
      static String get operatingSystemVersion;
      static String get localHostname;
      static bool get isLinux;
      static bool get isMacOS;
      static bool get isWindows;
      static bool get isAndroid;
      static bool get isIOS;
      static bool get isFuchsia;
      static Map<String, String> get environment;
      static String get executable;
      static String get resolvedExecutable;
      static Uri get script;
      static List<String> get executableArguments;
      static String? get packageConfig;
      static String get version;
      static String get lineTerminator;
    }
    final class ProcessStartMode {
      static const normal = ProcessStartMode._internal(0);
      static const inheritStdio = ProcessStartMode._internal(1);
      static const detached = ProcessStartMode._internal(2);
      static const detachedWithStdio = ProcessStartMode._internal(3);
    }
    final class ProcessSignal {
      static const ProcessSignal sighup = ProcessSignal._(1, "SIGHUP");
      static const ProcessSignal sigint = ProcessSignal._(2, "SIGINT");
      static const ProcessSignal sigkill = ProcessSignal._(9, "SIGKILL");
      static const ProcessSignal sigterm = ProcessSignal._(15, "SIGTERM");
      static const ProcessSignal sigusr1 = ProcessSignal._(10, "SIGUSR1");
      static const ProcessSignal sigusr2 = ProcessSignal._(12, "SIGUSR2");
      final int signalNumber;
      final String name;
      Stream<ProcessSignal> watch();
    }
    abstract interface class Process {
      Future<int> get exitCode;
      external static Future<Process> start(String executable, List<String> arguments, {String? workingDirectory, Map<String, String>? environment, bool includeParentEnvironment = true, bool runInShell = false, ProcessStartMode mode = ProcessStartMode.normal});
      external static Future<ProcessResult> run(String executable, List<String> arguments, {String? workingDirectory, Map<String, String>? environment, bool includeParentEnvironment = true, bool runInShell = false, Encoding? stdoutEncoding = systemEncoding, Encoding? stderrEncoding = systemEncoding});
      external static ProcessResult runSync(String executable, List<String> arguments, {String? workingDirectory, Map<String, String>? environment, bool includeParentEnvironment = true, bool runInShell = false, Encoding? stdoutEncoding = systemEncoding, Encoding? stderrEncoding = systemEncoding});
      external static bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]);
      Stream<List<int>> get stdout;
      Stream<List<int>> get stderr;
      IOSink get stdin;
      int get pid;
      bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
    }
    class ProcessResult {
      final int exitCode;
      final dynamic stdout;
      final dynamic stderr;
      final int pid;
      ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr);
    }
    abstract interface class InternetAddressType {
      static const InternetAddressType IPv4 = InternetAddressType._(0);
      static const InternetAddressType IPv6 = InternetAddressType._(1);
      static const InternetAddressType unix = InternetAddressType._(2);
      static const InternetAddressType any = InternetAddressType._(-1);
      String get name;
    }
    abstract interface class InternetAddress {
      static InternetAddress get loopbackIPv4;
      static InternetAddress get loopbackIPv6;
      static InternetAddress get anyIPv4;
      static InternetAddress get anyIPv6;
      InternetAddressType get type;
      String get address;
      String get host;
      Uint8List get rawAddress;
      bool get isLoopback;
      bool get isLinkLocal;
      bool get isMulticast;
      external factory InternetAddress(String address, {InternetAddressType? type});
      external factory InternetAddress.fromRawAddress(Uint8List rawAddress, {InternetAddressType? type});
      Future<InternetAddress> reverse();
      external static Future<List<InternetAddress>> lookup(String host, {InternetAddressType type = InternetAddressType.any});
      external static InternetAddress? tryParse(String address);
    }
    abstract interface class Socket implements Stream<Uint8List>, IOSink {
      static Future<Socket> connect(host, int port, {sourceAddress, int sourcePort = 0, Duration? timeout});
      void destroy();
      bool setOption(SocketOption option, bool enabled);
      Uint8List getRawOption(RawSocketOption option);
      void setRawOption(RawSocketOption option);
      int get port;
      int get remotePort;
      InternetAddress get address;
      InternetAddress get remoteAddress;
      Future get done;
    }
    abstract interface class ServerSocket implements Stream<Socket> {
      static Future<ServerSocket> bind(address, int port, {int backlog = 0, bool v6Only = false, bool shared = false});
      int get port;
      InternetAddress get address;
      Future<ServerSocket> close();
    }
    final class RawSocketOption {
      final int level;
      final int option;
      final Uint8List value;
      const RawSocketOption(this.level, this.option, this.value);
      factory RawSocketOption.fromInt(int level, int option, int value);
      factory RawSocketOption.fromBool(int level, int option, bool value);
      static int get levelSocket;
      static int get levelIPv4;
      static int get levelIPv6;
      static int get levelTcp;
      static int get levelUdp;
    }
    class WebSocketException implements IOException {
      final String message;
      const WebSocketException([this.message = ""]);
    }
    final class RawSocketEvent {
      static const RawSocketEvent read = RawSocketEvent._(0);
      static const RawSocketEvent write = RawSocketEvent._(1);
      static const RawSocketEvent readClosed = RawSocketEvent._(2);
      static const RawSocketEvent closed = RawSocketEvent._(3);
    }
    final class Datagram {
      Uint8List data;
      InternetAddress address;
      int port;
      Datagram(this.data, this.address, this.port);
    }
    abstract interface class RawDatagramSocket implements Stream<RawSocketEvent> {
      abstract bool readEventsEnabled;
      abstract bool writeEventsEnabled;
      abstract bool multicastLoopback;
      abstract int multicastHops;
      abstract bool broadcastEnabled;
      external static Future<RawDatagramSocket> bind(host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 1});
      int get port;
      InternetAddress get address;
      void close();
      int send(List<int> buffer, InternetAddress address, int port);
      Datagram? receive();
      void joinMulticast(InternetAddress group, [NetworkInterface? interface]);
      void leaveMulticast(InternetAddress group, [NetworkInterface? interface]);
    }
    abstract interface class NetworkInterface {
      String get name;
      int get index;
      List<InternetAddress> get addresses;
      external static Future<List<NetworkInterface>> list({bool includeLoopback = false, bool includeLinkLocal = false, InternetAddressType type = InternetAddressType.any});
    }
    abstract interface class SecurityContext {
      external factory SecurityContext({bool withTrustedRoots = false});
      external static SecurityContext get defaultContext;
      void usePrivateKey(String file, {String? password});
      void usePrivateKeyBytes(List<int> keyBytes, {String? password});
      void setTrustedCertificates(String file, {String? password});
      void setTrustedCertificatesBytes(List<int> certBytes, {String? password});
      void useCertificateChain(String file, {String? password});
      void useCertificateChainBytes(List<int> chainBytes, {String? password});
      void setAlpnProtocols(List<String> protocols, bool isServer);
    }
    abstract interface class X509Certificate {
      Uint8List get der;
      String get pem;
      Uint8List get sha1;
      String get subject;
      String get issuer;
      DateTime get startValidity;
      DateTime get endValidity;
    }
    abstract interface class HttpServer implements Stream<HttpRequest> {
      String? serverHeader;
      HttpHeaders get defaultResponseHeaders;
      bool autoCompress = false;
      Duration? idleTimeout = const Duration(seconds: 120);
      static Future<HttpServer> bind(address, int port, {int backlog = 0, bool v6Only = false, bool shared = false});
      static Future<HttpServer> bindSecure(address, int port, SecurityContext context, {int backlog = 0, bool v6Only = false, bool requestClientCertificate = false, bool shared = false});
      Future close({bool force = false});
      int get port;
      InternetAddress get address;
    }
    abstract interface class HttpRequest implements Stream<Uint8List> {
      int get contentLength;
      String get method;
      Uri get uri;
      Uri get requestedUri;
      HttpHeaders get headers;
      List<Cookie> get cookies;
      bool get persistentConnection;
      X509Certificate? get certificate;
      HttpSession get session;
      String get protocolVersion;
      HttpConnectionInfo? get connectionInfo;
      HttpResponse get response;
    }
    abstract interface class HttpResponse implements IOSink {
      int contentLength = -1;
      int statusCode = HttpStatus.ok;
      late String reasonPhrase;
      bool persistentConnection = true;
      Duration? deadline;
      bool bufferOutput = true;
      HttpHeaders get headers;
      List<Cookie> get cookies;
      Future redirect(Uri location, {int status = HttpStatus.movedTemporarily});
      Future<Socket> detachSocket({bool writeHeaders = true});
      HttpConnectionInfo? get connectionInfo;
    }
    abstract interface class HttpConnectionInfo {
      InternetAddress get remoteAddress;
      int get remotePort;
      int get localPort;
    }
    abstract interface class HttpSession implements Map {
      String get id;
      void destroy();
      bool get isNew;
    }
    abstract interface class HttpHeaders {
      static const acceptHeader = "accept";
      static const acceptEncodingHeader = "accept-encoding";
      static const authorizationHeader = "authorization";
      static const cacheControlHeader = "cache-control";
      static const connectionHeader = "connection";
      static const contentLengthHeader = "content-length";
      static const contentTypeHeader = "content-type";
      static const cookieHeader = "cookie";
      static const hostHeader = "host";
      static const locationHeader = "location";
      static const setCookieHeader = "set-cookie";
      static const userAgentHeader = "user-agent";
      static const upgradeHeader = "upgrade";
      static const accessControlAllowOriginHeader = "access-control-allow-origin";
      static const accessControlAllowMethodsHeader = "access-control-allow-methods";
      static const accessControlAllowHeadersHeader = "access-control-allow-headers";
      DateTime? date;
      DateTime? expires;
      DateTime? ifModifiedSince;
      String? host;
      int? port;
      ContentType? contentType;
      int contentLength = -1;
      late bool persistentConnection;
      late bool chunkedTransferEncoding;
      List<String>? operator [](String name);
      String? value(String name);
      void add(String name, Object value, {bool preserveHeaderCase = false});
      void set(String name, Object value, {bool preserveHeaderCase = false});
      void remove(String name, Object value);
      void removeAll(String name);
      void forEach(void action(String name, List<String> values));
      void noFolding(String name);
      void clear();
    }
    abstract interface class HeaderValue {
      factory HeaderValue([String value = "", Map<String, String?> parameters = const {}]);
      static HeaderValue parse(String value, {String parameterSeparator = ";", String? valueSeparator, bool preserveBackslash = false});
      String get value;
      Map<String, String?> get parameters;
    }
    abstract interface class ContentType implements HeaderValue {
      static final text = ContentType("text", "plain", charset: "utf-8");
      static final html = ContentType("text", "html", charset: "utf-8");
      static final json = ContentType("application", "json", charset: "utf-8");
      static final binary = ContentType("application", "octet-stream");
      factory ContentType(String primaryType, String subType, {String? charset, Map<String, String?> parameters = const {}});
      static ContentType parse(String value);
      String get mimeType;
      String get primaryType;
      String get subType;
      String? get charset;
    }
    abstract interface class Cookie {
      String name;
      String value;
      DateTime? expires;
      int? maxAge;
      String? domain;
      String? path;
      bool secure;
      bool httpOnly;
      factory Cookie(String name, String value);
      factory Cookie.fromSetCookieValue(String value);
    }
    abstract final class HttpStatus {
      static const int continue_ = 100;
      static const int switchingProtocols = 101;
      static const int ok = 200;
      static const int created = 201;
      static const int accepted = 202;
      static const int noContent = 204;
      static const int partialContent = 206;
      static const int movedPermanently = 301;
      static const int found = 302;
      static const int movedTemporarily = 302;
      static const int seeOther = 303;
      static const int notModified = 304;
      static const int temporaryRedirect = 307;
      static const int permanentRedirect = 308;
      static const int badRequest = 400;
      static const int unauthorized = 401;
      static const int paymentRequired = 402;
      static const int forbidden = 403;
      static const int notFound = 404;
      static const int methodNotAllowed = 405;
      static const int notAcceptable = 406;
      static const int requestTimeout = 408;
      static const int conflict = 409;
      static const int gone = 410;
      static const int lengthRequired = 411;
      static const int preconditionFailed = 412;
      static const int requestEntityTooLarge = 413;
      static const int unsupportedMediaType = 415;
      static const int unprocessableEntity = 422;
      static const int tooManyRequests = 429;
      static const int internalServerError = 500;
      static const int notImplemented = 501;
      static const int badGateway = 502;
      static const int serviceUnavailable = 503;
      static const int gatewayTimeout = 504;
    }
    abstract interface class HttpClient {
      static const int defaultHttpPort = 80;
      static const int defaultHttpsPort = 443;
      Duration idleTimeout = const Duration(seconds: 15);
      Duration? connectionTimeout;
      int? maxConnectionsPerHost;
      bool autoUncompress = true;
      String? userAgent;
      factory HttpClient({SecurityContext? context});
      Future<HttpClientRequest> open(String method, String host, int port, String path);
      Future<HttpClientRequest> openUrl(String method, Uri url);
      Future<HttpClientRequest> get(String host, int port, String path);
      Future<HttpClientRequest> getUrl(Uri url);
      Future<HttpClientRequest> post(String host, int port, String path);
      Future<HttpClientRequest> postUrl(Uri url);
      Future<HttpClientRequest> put(String host, int port, String path);
      Future<HttpClientRequest> putUrl(Uri url);
      Future<HttpClientRequest> delete(String host, int port, String path);
      Future<HttpClientRequest> deleteUrl(Uri url);
      Future<HttpClientRequest> patchUrl(Uri url);
      Future<HttpClientRequest> headUrl(Uri url);
      set findProxy(String Function(Uri url)? f);
      set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback);
      void close({bool force = false});
    }
    abstract interface class HttpClientRequest implements IOSink {
      bool persistentConnection = true;
      bool followRedirects = true;
      int maxRedirects = 5;
      int contentLength = -1;
      bool bufferOutput = true;
      String get method;
      Uri get uri;
      HttpHeaders get headers;
      List<Cookie> get cookies;
      Future<HttpClientResponse> get done;
      Future<HttpClientResponse> close();
      void abort([Object? exception, StackTrace? stackTrace]);
      HttpConnectionInfo? get connectionInfo;
    }
    abstract interface class HttpClientResponse implements Stream<List<int>> {
      int get statusCode;
      String get reasonPhrase;
      int get contentLength;
      HttpClientResponseCompressionState get compressionState;
      bool get persistentConnection;
      bool get isRedirect;
      List<RedirectInfo> get redirects;
      Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]);
      HttpHeaders get headers;
      Future<Socket> detachSocket();
      List<Cookie> get cookies;
      X509Certificate? get certificate;
      HttpConnectionInfo? get connectionInfo;
    }
    abstract interface class WebSocket implements Stream<dynamic>, StreamSink<dynamic> {
      static const int connecting = 0;
      static const int open = 1;
      static const int closing = 2;
      static const int closed = 3;
      Duration? pingInterval;
      static Future<WebSocket> connect(String url, {Iterable<String>? protocols, Map<String, dynamic>? headers, HttpClient? customClient});
      factory WebSocket.fromUpgradedSocket(Socket socket, {String? protocol, bool? serverSide, CompressionOptions compression = CompressionOptions.compressionDefault});
      int get readyState;
      String? get extensions;
      String? get protocol;
      int? get closeCode;
      String? get closeReason;
      Future close([int? code, String? reason]);
      void add(dynamic data);
      Future addStream(Stream stream);
      void addUtf8Text(List<int> bytes);
    }
    abstract interface class WebSocketTransformer implements StreamTransformer<HttpRequest, WebSocket> {
      static Future<WebSocket> upgrade(HttpRequest request, {dynamic Function(List<String> protocols)? protocolSelector, CompressionOptions compression = CompressionOptions.compressionDefault});
      static bool isUpgradeRequest(HttpRequest request);
    }
    abstract final class WebSocketStatus {
      static const int normalClosure = 1000;
      static const int goingAway = 1001;
      static const int protocolError = 1002;
      static const int internalServerError = 1011;
    }
    const GZipCodec gzip = GZipCodec();
    const ZLibCodec zlib = ZLibCodec();
    final class GZipCodec extends Codec<List<int>, List<int>> {
      const GZipCodec({int level = ZLibOption.defaultLevel});
      List<int> encode(List<int> input);
      List<int> decode(List<int> encoded);
    }
    final class ZLibCodec extends Codec<List<int>, List<int>> {
      const ZLibCodec({int level = ZLibOption.defaultLevel});
      List<int> encode(List<int> input);
      List<int> decode(List<int> encoded);
    }
    """#

  static let typedData = header + #"""
    library dart.typed_data;

    abstract final class ByteBuffer {
      int get lengthInBytes;
      Uint8List asUint8List([int offsetInBytes = 0, int? length]);
      Int8List asInt8List([int offsetInBytes = 0, int? length]);
      Uint16List asUint16List([int offsetInBytes = 0, int? length]);
      Int16List asInt16List([int offsetInBytes = 0, int? length]);
      Uint32List asUint32List([int offsetInBytes = 0, int? length]);
      Int32List asInt32List([int offsetInBytes = 0, int? length]);
      Uint64List asUint64List([int offsetInBytes = 0, int? length]);
      Int64List asInt64List([int offsetInBytes = 0, int? length]);
      Float32List asFloat32List([int offsetInBytes = 0, int? length]);
      Float64List asFloat64List([int offsetInBytes = 0, int? length]);
      ByteData asByteData([int offsetInBytes = 0, int? length]);
    }
    abstract final class TypedData {
      int get elementSizeInBytes;
      int get offsetInBytes;
      int get lengthInBytes;
      ByteBuffer get buffer;
    }
    final class Endian {
      static const Endian big = Endian._(false);
      static const Endian little = Endian._(true);
      static final Endian host = little;
    }
    abstract final class ByteData implements TypedData {
      external factory ByteData(int length);
      factory ByteData.view(ByteBuffer buffer, [int offsetInBytes = 0, int? length]);
      factory ByteData.sublistView(TypedData data, [int start = 0, int? end]);
      int getInt8(int byteOffset);
      void setInt8(int byteOffset, int value);
      int getUint8(int byteOffset);
      void setUint8(int byteOffset, int value);
      int getInt16(int byteOffset, [Endian endian = Endian.big]);
      void setInt16(int byteOffset, int value, [Endian endian = Endian.big]);
      int getUint16(int byteOffset, [Endian endian = Endian.big]);
      void setUint16(int byteOffset, int value, [Endian endian = Endian.big]);
      int getInt32(int byteOffset, [Endian endian = Endian.big]);
      void setInt32(int byteOffset, int value, [Endian endian = Endian.big]);
      int getUint32(int byteOffset, [Endian endian = Endian.big]);
      void setUint32(int byteOffset, int value, [Endian endian = Endian.big]);
      int getInt64(int byteOffset, [Endian endian = Endian.big]);
      void setInt64(int byteOffset, int value, [Endian endian = Endian.big]);
      int getUint64(int byteOffset, [Endian endian = Endian.big]);
      void setUint64(int byteOffset, int value, [Endian endian = Endian.big]);
      double getFloat32(int byteOffset, [Endian endian = Endian.big]);
      void setFloat32(int byteOffset, double value, [Endian endian = Endian.big]);
      double getFloat64(int byteOffset, [Endian endian = Endian.big]);
      void setFloat64(int byteOffset, double value, [Endian endian = Endian.big]);
    }
    abstract final class Uint8List implements List<int>, TypedData {
      external factory Uint8List(int length);
      external factory Uint8List.fromList(List<int> elements);
      factory Uint8List.view(ByteBuffer buffer, [int offsetInBytes = 0, int? length]);
      factory Uint8List.sublistView(TypedData data, [int start = 0, int? end]);
      static const int bytesPerElement = 1;
      List<int> operator +(List<int> other);
      Uint8List sublist(int start, [int? end]);
    }
    abstract final class Int8List implements List<int>, TypedData {
      external factory Int8List(int length);
      external factory Int8List.fromList(List<int> elements);
      Int8List sublist(int start, [int? end]);
    }
    abstract final class Uint16List implements List<int>, TypedData {
      external factory Uint16List(int length);
      external factory Uint16List.fromList(List<int> elements);
      Uint16List sublist(int start, [int? end]);
    }
    abstract final class Int16List implements List<int>, TypedData {
      external factory Int16List(int length);
      external factory Int16List.fromList(List<int> elements);
      Int16List sublist(int start, [int? end]);
    }
    abstract final class Uint32List implements List<int>, TypedData {
      external factory Uint32List(int length);
      external factory Uint32List.fromList(List<int> elements);
      Uint32List sublist(int start, [int? end]);
    }
    abstract final class Int32List implements List<int>, TypedData {
      external factory Int32List(int length);
      external factory Int32List.fromList(List<int> elements);
      Int32List sublist(int start, [int? end]);
    }
    abstract final class Uint64List implements List<int>, TypedData {
      external factory Uint64List(int length);
      external factory Uint64List.fromList(List<int> elements);
      Uint64List sublist(int start, [int? end]);
    }
    abstract final class Int64List implements List<int>, TypedData {
      external factory Int64List(int length);
      external factory Int64List.fromList(List<int> elements);
      Int64List sublist(int start, [int? end]);
    }
    abstract final class Float32List implements List<double>, TypedData {
      external factory Float32List(int length);
      external factory Float32List.fromList(List<double> elements);
      Float32List sublist(int start, [int? end]);
    }
    abstract final class Float64List implements List<double>, TypedData {
      external factory Float64List(int length);
      external factory Float64List.fromList(List<double> elements);
      Float64List sublist(int start, [int? end]);
    }
    abstract interface class BytesBuilder {
      factory BytesBuilder({bool copy = true});
      void add(List<int> bytes);
      void addByte(int byte);
      Uint8List takeBytes();
      Uint8List toBytes();
      int get length;
      bool get isEmpty;
      bool get isNotEmpty;
      void clear();
    }
    """#

  static let math = header + #"""
    library dart.math;

    const double e = 2.718281828459045;
    const double ln10 = 2.302585092994046;
    const double ln2 = 0.6931471805599453;
    const double log2e = 1.4426950408889634;
    const double log10e = 0.4342944819032518;
    const double pi = 3.1415926535897932;
    const double sqrt1_2 = 0.7071067811865476;
    const double sqrt2 = 1.4142135623730951;
    external T min<T extends num>(T a, T b);
    external T max<T extends num>(T a, T b);
    external double atan2(num a, num b);
    external num pow(num x, num exponent);
    external double sin(num radians);
    external double cos(num radians);
    external double tan(num radians);
    external double acos(num x);
    external double asin(num x);
    external double atan(num x);
    external double sqrt(num x);
    external double exp(num x);
    external double log(num x);
    abstract interface class Random {
      external factory Random([int? seed]);
      external factory Random.secure();
      int nextInt(int max);
      double nextDouble();
      bool nextBool();
    }
    final class Point<T extends num> {
      final T x;
      final T y;
      const Point(T x, T y);
      Point<T> operator +(Point<T> other);
      Point<T> operator -(Point<T> other);
      Point<T> operator *(num factor);
      double get magnitude;
      double distanceTo(Point<T> other);
      T squaredDistanceTo(Point<T> other);
    }
    class Rectangle<T extends num> {
      final T left;
      final T top;
      final T width;
      final T height;
      const Rectangle(this.left, this.top, T width, T height);
      T get right;
      T get bottom;
      bool containsPoint(Point<num> another);
      bool intersects(Rectangle<num> other);
    }
    """#

  static let developer = header + #"""
    library dart.developer;

    external void log(String message, {DateTime? time, int? sequenceNumber, int level = 0, String name = '', Zone? zone, Object? error, StackTrace? stackTrace});
    external bool debugger({bool when = true, String? message});
    external Object? inspect(Object? object);
    void postEvent(String eventKind, Map eventData, {String stream = 'Extension'});
    void registerExtension(String method, ServiceExtensionHandler handler);
    abstract final class Timeline {
      static void startSync(String name, {Map? arguments, Flow? flow});
      static void finishSync();
      static T timeSync<T>(String name, TimelineSyncFunction<T> function, {Map? arguments, Flow? flow});
      static void instantSync(String name, {Map? arguments});
    }
    final class Service {
      static Future<ServiceProtocolInfo> getInfo();
      static Future<ServiceProtocolInfo> controlWebServer({bool enable = false, bool? silenceOutput});
    }
    """#

  static let isolate = header + #"""
    library dart.isolate;

    import 'dart:async';

    final class Isolate {
      static const int immediate = 0;
      static const int beforeNextEvent = 1;
      final SendPort controlPort;
      Capability? pauseCapability;
      Capability? terminateCapability;
      external String? get debugName;
      external static Isolate get current;
      external static Future<Uri?> get packageConfig;
      external static Future<Uri?> resolvePackageUri(Uri packageUri);
      external static Future<Isolate> spawn<T>(void entryPoint(T message), T message, {bool paused = false, bool errorsAreFatal = true, SendPort? onExit, SendPort? onError, String? debugName});
      external static Future<Isolate> spawnUri(Uri uri, List<String> args, var message, {bool paused = false, SendPort? onExit, SendPort? onError, bool errorsAreFatal = true, bool? checked, Map<String, String>? environment, Uri? packageConfig, bool automaticPackageResolution = false, String? debugName});
      external static Future<R> run<R>(FutureOr<R> computation(), {String? debugName});
      external static Never exit([SendPort? finalMessagePort, Object? message]);
      Capability pause([Capability? resumeCapability]);
      external void resume(Capability resumeCapability);
      external void addOnExitListener(SendPort responsePort, {Object? response});
      external void removeOnExitListener(SendPort responsePort);
      external void addErrorListener(SendPort port);
      external void removeErrorListener(SendPort port);
      external void kill({int priority = beforeNextEvent});
      Stream get errors;
    }
    abstract interface class SendPort implements Capability {
      void send(Object? message);
    }
    abstract interface class ReceivePort implements Stream<dynamic> {
      external factory ReceivePort([String debugName = '']);
      external factory ReceivePort.fromRawReceivePort(RawReceivePort rawPort);
      StreamSubscription<dynamic> listen(void onData(var message)?, {Function? onError, void onDone()?, bool? cancelOnError});
      void close();
      SendPort get sendPort;
    }
    abstract interface class RawReceivePort {
      external factory RawReceivePort([Function? handler, String debugName = '']);
      set handler(Function? newHandler);
      void close();
      SendPort get sendPort;
    }
    class Capability {
      external factory Capability();
    }
    class IsolateSpawnException implements Exception {
      final String message;
      IsolateSpawnException(this.message);
    }
    class RemoteError implements Error {
      final String _description;
      final StackTrace stackTrace;
      RemoteError(String description, String stackDescription);
    }
    abstract final class TransferableTypedData {
      external factory TransferableTypedData.fromList(List<TypedData> list);
      ByteBuffer materialize();
    }
    """#

  static let collection = header + #"""
    library dart.collection;

    abstract final class HashMap<K, V> implements Map<K, V> {
      external factory HashMap({bool Function(K, K)? equals, int Function(K)? hashCode, bool Function(dynamic)? isValidKey});
      external factory HashMap.identity();
      factory HashMap.from(Map<dynamic, dynamic> other);
      factory HashMap.of(Map<K, V> other);
      factory HashMap.fromIterable(Iterable iterable, {K Function(dynamic element)? key, V Function(dynamic element)? value});
      factory HashMap.fromIterables(Iterable<K> keys, Iterable<V> values);
      factory HashMap.fromEntries(Iterable<MapEntry<K, V>> entries);
    }
    abstract final class LinkedHashMap<K, V> implements Map<K, V> {
      external factory LinkedHashMap({bool Function(K, K)? equals, int Function(K)? hashCode, bool Function(dynamic)? isValidKey});
      external factory LinkedHashMap.identity();
      factory LinkedHashMap.from(Map<dynamic, dynamic> other);
      factory LinkedHashMap.of(Map<K, V> other);
      factory LinkedHashMap.fromIterable(Iterable iterable, {K Function(dynamic element)? key, V Function(dynamic element)? value});
      factory LinkedHashMap.fromIterables(Iterable<K> keys, Iterable<V> values);
      factory LinkedHashMap.fromEntries(Iterable<MapEntry<K, V>> entries);
    }
    abstract final class HashSet<E> implements Set<E> {
      external factory HashSet({bool Function(E, E)? equals, int Function(E)? hashCode, bool Function(dynamic)? isValidKey});
      external factory HashSet.identity();
      factory HashSet.from(Iterable<dynamic> elements);
      factory HashSet.of(Iterable<E> elements);
    }
    abstract final class LinkedHashSet<E> implements Set<E> {
      external factory LinkedHashSet({bool Function(E, E)? equals, int Function(E)? hashCode, bool Function(dynamic)? isValidKey});
      external factory LinkedHashSet.identity();
      factory LinkedHashSet.from(Iterable<dynamic> elements);
      factory LinkedHashSet.of(Iterable<E> elements);
    }
    final class SplayTreeMap<K, V> extends _SplayTree<K, _SplayTreeMapNode<K, V>> with MapMixin<K, V> {
      SplayTreeMap([int Function(K key1, K key2)? compare, bool Function(dynamic potentialKey)? isValidKey]);
      factory SplayTreeMap.from(Map<dynamic, dynamic> other, [int Function(K key1, K key2)? compare, bool Function(dynamic potentialKey)? isValidKey]);
      factory SplayTreeMap.of(Map<K, V> other, [int Function(K key1, K key2)? compare, bool Function(dynamic potentialKey)? isValidKey]);
      K? firstKey();
      K? lastKey();
      K? lastKeyBefore(K key);
      K? firstKeyAfter(K key);
    }
    final class SplayTreeSet<E> extends _SplayTree<E, _SplayTreeSetNode<E>> with Iterable<E>, SetMixin<E> {
      SplayTreeSet([int Function(E key1, E key2)? compare, bool Function(dynamic potentialKey)? isValidKey]);
      factory SplayTreeSet.from(Iterable elements, [int Function(E key1, E key2)? compare, bool Function(dynamic potentialKey)? isValidKey]);
      factory SplayTreeSet.of(Iterable<E> elements, [int Function(E key1, E key2)? compare, bool Function(dynamic potentialKey)? isValidKey]);
    }
    abstract interface class Queue<E> implements Iterable<E> {
      factory Queue() = ListQueue<E>;
      factory Queue.from(Iterable<dynamic> elements) = ListQueue<E>.from;
      factory Queue.of(Iterable<E> elements) = ListQueue<E>.of;
      E removeFirst();
      E removeLast();
      void addFirst(E value);
      void addLast(E value);
      void add(E value);
      bool remove(Object? value);
      void addAll(Iterable<E> iterable);
      void removeWhere(bool test(E element));
      void retainWhere(bool test(E element));
      void clear();
    }
    final class ListQueue<E> extends ListIterable<E> implements Queue<E> {
      ListQueue([int? initialCapacity]);
      factory ListQueue.from(Iterable<dynamic> elements);
      factory ListQueue.of(Iterable<E> elements);
    }
    class DoubleLinkedQueue<E> extends Iterable<E> implements Queue<E> {
      DoubleLinkedQueue();
      factory DoubleLinkedQueue.from(Iterable<dynamic> elements);
      factory DoubleLinkedQueue.of(Iterable<E> elements);
    }
    class UnmodifiableListView<E> extends UnmodifiableListBase<E> {
      UnmodifiableListView(Iterable<E> source);
    }
    class UnmodifiableMapView<K, V> extends MapView<K, V> with _UnmodifiableMapMixin<K, V> {
      UnmodifiableMapView(Map<K, V> map);
    }
    class MapView<K, V> implements Map<K, V> {
      const MapView(Map<K, V> map);
    }
    abstract class MapBase<K, V> extends MapMixin<K, V> {}
    abstract mixin class MapMixin<K, V> implements Map<K, V> {}
    abstract class ListBase<E> with ListMixin<E> {}
    abstract mixin class ListMixin<E> implements List<E> {}
    abstract class SetBase<E> with SetMixin<E> {}
    abstract mixin class SetMixin<E> implements Set<E> {}
    abstract mixin class IterableMixin<E> implements Iterable<E> {}
    abstract class IterableBase<E> extends Iterable<E> {
      const IterableBase();
    }
    """#

  static let ffi = header + #"""
    library dart.ffi;

    import 'dart:typed_data';

    abstract final class NativeType {}
    abstract final class SizedNativeType implements NativeType {}
    abstract base class Opaque implements NativeType {}
    abstract base class Struct implements SizedNativeType {}
    abstract base class Union implements SizedNativeType {}
    final class Void implements NativeType {}
    final class Handle implements NativeType {}
    final class Int8 implements SizedNativeType {}
    final class Int16 implements SizedNativeType {}
    final class Int32 implements SizedNativeType {}
    final class Int64 implements SizedNativeType {}
    final class Uint8 implements SizedNativeType {}
    final class Uint16 implements SizedNativeType {}
    final class Uint32 implements SizedNativeType {}
    final class Uint64 implements SizedNativeType {}
    final class Float implements SizedNativeType {}
    final class Double implements SizedNativeType {}
    final class Bool implements SizedNativeType {}
    abstract base class AbiSpecificInteger implements SizedNativeType {
      const AbiSpecificInteger();
    }
    final class Char extends AbiSpecificInteger { const Char(); }
    final class SignedChar extends AbiSpecificInteger { const SignedChar(); }
    final class UnsignedChar extends AbiSpecificInteger { const UnsignedChar(); }
    final class Short extends AbiSpecificInteger { const Short(); }
    final class UnsignedShort extends AbiSpecificInteger { const UnsignedShort(); }
    final class Int extends AbiSpecificInteger { const Int(); }
    final class UnsignedInt extends AbiSpecificInteger { const UnsignedInt(); }
    final class Long extends AbiSpecificInteger { const Long(); }
    final class UnsignedLong extends AbiSpecificInteger { const UnsignedLong(); }
    final class LongLong extends AbiSpecificInteger { const LongLong(); }
    final class UnsignedLongLong extends AbiSpecificInteger { const UnsignedLongLong(); }
    final class Size extends AbiSpecificInteger { const Size(); }
    final class IntPtr extends AbiSpecificInteger { const IntPtr(); }
    final class UintPtr extends AbiSpecificInteger { const UintPtr(); }
    final class WChar extends AbiSpecificInteger { const WChar(); }
    extension AbiSpecificIntegerPointer<T extends AbiSpecificInteger> on Pointer<T> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
    }
    final class NativeCallable<T extends Function> {
      factory NativeCallable.isolateLocal(Function callback, {Object? exceptionalReturn});
      factory NativeCallable.listener(Function callback);
      Pointer<NativeFunction<T>> get nativeFunction;
      void close();
      bool get keepIsolateAlive;
      set keepIsolateAlive(bool value);
    }
    final class NativeFunction<T extends Function> implements NativeType {}
    final class Array<T extends NativeType> implements NativeType {
      const factory Array(int dimension1, [int dimension2, int dimension3, int dimension4, int dimension5]);
    }
    final class Pointer<T extends NativeType> implements SizedNativeType {
      external factory Pointer.fromAddress(int ptr);
      external static Pointer<NativeFunction<T>> fromFunction<T extends Function>(Function f, [Object? exceptionalReturn]);
      external int get address;
      external Pointer<U> cast<U extends NativeType>();
      external bool operator ==(Object other);
      external int get hashCode;
    }
    final Pointer<Never> nullptr = Pointer.fromAddress(0);
    external int sizeOf<T extends SizedNativeType>();
    final class DynamicLibrary {
      external factory DynamicLibrary.process();
      external factory DynamicLibrary.executable();
      external factory DynamicLibrary.open(String path);
      external Pointer<T> lookup<T extends NativeType>(String symbolName);
      external bool providesSymbol(String symbolName);
      external void close();
      external int get handle;
    }
    extension DynamicLibraryExtension on DynamicLibrary {
      external F lookupFunction<T extends Function, F extends Function>(String symbolName, {bool isLeaf = false});
    }
    extension NativeFunctionPointer<NF extends Function> on Pointer<NativeFunction<NF>> {
      external DF asFunction<DF extends Function>({bool isLeaf = false});
    }
    extension Int8Pointer on Pointer<Int8> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Int8List asTypedList(int length);
    }
    extension Int16Pointer on Pointer<Int16> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Int16List asTypedList(int length);
    }
    extension Int32Pointer on Pointer<Int32> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Int32List asTypedList(int length);
    }
    extension Int64Pointer on Pointer<Int64> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Int64List asTypedList(int length);
    }
    extension Uint8Pointer on Pointer<Uint8> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Uint8List asTypedList(int length, {Pointer<NativeFinalizerFunction>? finalizer, Pointer<Void>? token});
    }
    extension Uint16Pointer on Pointer<Uint16> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Uint16List asTypedList(int length);
    }
    extension Uint32Pointer on Pointer<Uint32> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Uint32List asTypedList(int length);
    }
    extension Uint64Pointer on Pointer<Uint64> {
      external int get value;
      external set value(int value);
      external int operator [](int index);
      external void operator []=(int index, int value);
      external Uint64List asTypedList(int length);
    }
    extension FloatPointer on Pointer<Float> {
      external double get value;
      external set value(double value);
      external double operator [](int index);
      external void operator []=(int index, double value);
      external Float32List asTypedList(int length);
    }
    extension DoublePointer on Pointer<Double> {
      external double get value;
      external set value(double value);
      external double operator [](int index);
      external void operator []=(int index, double value);
      external Float64List asTypedList(int length);
    }
    extension BoolPointer on Pointer<Bool> {
      external bool get value;
      external set value(bool value);
      external bool operator [](int index);
      external void operator []=(int index, bool value);
    }
    extension PointerPointer<T extends NativeType> on Pointer<Pointer<T>> {
      external Pointer<T> get value;
      external set value(Pointer<T> value);
      external Pointer<T> operator [](int index);
      external void operator []=(int index, Pointer<T> value);
    }
    extension StructPointer<T extends Struct> on Pointer<T> {
      external T get ref;
      external set ref(T value);
      external T operator [](int index);
    }
    extension PointerArithmetic<T extends NativeType> on Pointer<T> {
      external Pointer<T> operator +(int offset);
      external Pointer<T> operator -(int offset);
      external Pointer<T> elementAt(int index);
    }
    abstract final class NativeFinalizerFunction {}
    abstract final class Finalizable {}
    abstract interface class Allocator {
      Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment});
      void free(Pointer pointer);
    }
    extension AllocatorAlloc on Allocator {
      external Pointer<T> call<T extends SizedNativeType>([int count = 1]);
    }
    final class Native<T> {
      final String? symbol;
      final String? assetId;
      final bool isLeaf;
      const Native({this.assetId, this.isLeaf = false, this.symbol});
    }
    final class Packed {
      final int memberAlignment;
      const Packed(this.memberAlignment);
    }
    """#
}
