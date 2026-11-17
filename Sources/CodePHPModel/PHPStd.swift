import Foundation

/// A hand-written stub of PHP's own declarations most code uses, read when no stubs are on disk (see `PHPLayout`). It is
/// not PHP's source: the signatures are written from PHP 8.4's documentation, with empty bodies, no documentation and
/// without the functions, classes and extensions few programs use. Names it doesn't have stay unknown.
enum PHPStd {
  static let source = #"""
    <?php
    // Code's hand-written stub of PHP's built-in declarations (not PHP itself): the functions, classes and constants most
    // code uses, from PHP 8.4's documentation. Superglobals first.

    $GLOBALS = [];
    $_SERVER = [];
    $_GET = [];
    $_POST = [];
    $_FILES = [];
    $_COOKIE = [];
    $_SESSION = [];
    $_REQUEST = [];
    $_ENV = [];
    $argv = [];
    $argc = 0;
    $http_response_header = [];

    // Interfaces and classes of the core.

    interface Traversable {}
    interface Iterator extends Traversable {
      public function current(): mixed {}
      public function next(): void {}
      public function key(): mixed {}
      public function valid(): bool {}
      public function rewind(): void {}
    }
    interface IteratorAggregate extends Traversable {
      public function getIterator(): Iterator {}
    }
    interface ArrayAccess {
      public function offsetExists(mixed $offset): bool {}
      public function offsetGet(mixed $offset): mixed {}
      public function offsetSet(mixed $offset, mixed $value): void {}
      public function offsetUnset(mixed $offset): void {}
    }
    interface Countable {
      public function count(): int {}
    }
    interface Stringable {
      public function __toString(): string {}
    }
    interface JsonSerializable {
      public function jsonSerialize(): mixed {}
    }
    interface Serializable {
      public function serialize() {}
      public function unserialize(string $data) {}
    }
    interface UnitEnum {
      public static function cases(): array {}
    }
    interface BackedEnum extends UnitEnum {
      public static function from(int|string $value): static {}
      public static function tryFrom(int|string $value): ?static {}
    }

    interface Throwable extends Stringable {
      public function getMessage(): string {}
      public function getCode() {}
      public function getFile(): string {}
      public function getLine(): int {}
      public function getTrace(): array {}
      public function getTraceAsString(): string {}
      public function getPrevious(): ?Throwable {}
    }
    class Exception implements Throwable {
      protected $message = "";
      protected $code = 0;
      protected string $file = "";
      protected int $line = 0;
      public function __construct(string $message = "", int $code = 0, ?Throwable $previous = null) {}
      final public function getMessage(): string {}
      final public function getCode() {}
      final public function getFile(): string {}
      final public function getLine(): int {}
      final public function getTrace(): array {}
      final public function getTraceAsString(): string {}
      final public function getPrevious(): ?Throwable {}
      public function __toString(): string {}
    }
    class Error implements Throwable {
      protected $message = "";
      protected $code = 0;
      protected string $file = "";
      protected int $line = 0;
      public function __construct(string $message = "", int $code = 0, ?Throwable $previous = null) {}
      final public function getMessage(): string {}
      final public function getCode() {}
      final public function getFile(): string {}
      final public function getLine(): int {}
      final public function getTrace(): array {}
      final public function getTraceAsString(): string {}
      final public function getPrevious(): ?Throwable {}
      public function __toString(): string {}
    }
    class ErrorException extends Exception {
      public function __construct(string $message = "", int $code = 0, int $severity = E_ERROR, ?string $filename = null, ?int $line = null, ?Throwable $previous = null) {}
      final public function getSeverity(): int {}
    }
    class TypeError extends Error {}
    class ValueError extends Error {}
    class ArithmeticError extends Error {}
    class DivisionByZeroError extends ArithmeticError {}
    class ArgumentCountError extends TypeError {}
    class AssertionError extends Error {}
    class UnhandledMatchError extends Error {}
    class JsonException extends Exception {}
    class LogicException extends Exception {}
    class BadFunctionCallException extends LogicException {}
    class BadMethodCallException extends BadFunctionCallException {}
    class DomainException extends LogicException {}
    class InvalidArgumentException extends LogicException {}
    class LengthException extends LogicException {}
    class OutOfRangeException extends LogicException {}
    class RuntimeException extends Exception {}
    class OutOfBoundsException extends RuntimeException {}
    class OverflowException extends RuntimeException {}
    class RangeException extends RuntimeException {}
    class UnderflowException extends RuntimeException {}
    class UnexpectedValueException extends RuntimeException {}

    class stdClass {}

    final class Closure {
      public static function bind(Closure $closure, ?object $newThis, object|string|null $newScope = "static"): ?Closure {}
      public function bindTo(?object $newThis, object|string|null $newScope = "static"): ?Closure {}
      public function call(object $newThis, mixed ...$args): mixed {}
      public static function fromCallable(callable $callback): Closure {}
      public function __invoke(...$args) {}
    }

    final class Generator implements Iterator {
      public function current(): mixed {}
      public function next(): void {}
      public function key(): mixed {}
      public function valid(): bool {}
      public function rewind(): void {}
      public function send(mixed $value): mixed {}
      public function throw(Throwable $exception): mixed {}
      public function getReturn(): mixed {}
    }

    final class Fiber {
      public function __construct(callable $callback) {}
      public function start(mixed ...$args): mixed {}
      public function resume(mixed $value = null): mixed {}
      public function throw(Throwable $exception): mixed {}
      public function getReturn(): mixed {}
      public function isStarted(): bool {}
      public function isSuspended(): bool {}
      public function isRunning(): bool {}
      public function isTerminated(): bool {}
      public static function suspend(mixed $value = null): mixed {}
      public static function getCurrent(): ?Fiber {}
    }

    final class WeakReference {
      public static function create(object $object): WeakReference {}
      public function get(): ?object {}
    }
    final class WeakMap implements ArrayAccess, Countable, IteratorAggregate {
      public function offsetExists($object): bool {}
      public function offsetGet($object): mixed {}
      public function offsetSet($object, mixed $value): void {}
      public function offsetUnset($object): void {}
      public function count(): int {}
      public function getIterator(): Iterator {}
    }

    #[Attribute(Attribute::TARGET_CLASS)]
    final class Attribute {
      const TARGET_CLASS = 1;
      const TARGET_FUNCTION = 2;
      const TARGET_METHOD = 4;
      const TARGET_PROPERTY = 8;
      const TARGET_CLASS_CONSTANT = 16;
      const TARGET_PARAMETER = 32;
      const TARGET_ALL = 63;
      const IS_REPEATABLE = 64;
      public int $flags;
      public function __construct(int $flags = Attribute::TARGET_ALL) {}
    }
    final class ReturnTypeWillChange { public function __construct() {} }
    final class AllowDynamicProperties { public function __construct() {} }
    final class SensitiveParameter { public function __construct() {} }
    final class Override { public function __construct() {} }
    final class Deprecated {
      public function __construct(?string $message = null, ?string $since = null) {}
    }

    class PhpToken implements Stringable {
      public int $id;
      public string $text;
      public int $line;
      public int $pos;
      final public function __construct(int $id, string $text, int $line = -1, int $pos = -1) {}
      public function getTokenName(): ?string {}
      public static function tokenize(string $code, int $flags = 0): array {}
      public function is($kind): bool {}
      public function isIgnorable(): bool {}
      public function __toString(): string {}
    }

    // SPL.

    class ArrayIterator implements SeekableIterator, ArrayAccess, Countable, Serializable {
      public function __construct(array|object $array = [], int $flags = 0) {}
      public function offsetExists(mixed $key): bool {}
      public function offsetGet(mixed $key): mixed {}
      public function offsetSet(mixed $key, mixed $value): void {}
      public function offsetUnset(mixed $key): void {}
      public function append(mixed $value): void {}
      public function getArrayCopy(): array {}
      public function count(): int {}
      public function current(): mixed {}
      public function key(): string|int|null {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
      public function seek(int $offset): void {}
      public function serialize() {}
      public function unserialize(string $data) {}
    }
    interface SeekableIterator extends Iterator {
      public function seek(int $offset): void {}
    }
    interface OuterIterator extends Iterator {
      public function getInnerIterator(): ?Iterator {}
    }
    class IteratorIterator implements OuterIterator {
      public function __construct(Traversable $iterator, ?string $class = null) {}
      public function getInnerIterator(): ?Iterator {}
      public function current(): mixed {}
      public function key(): mixed {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
    }
    class ArrayObject implements IteratorAggregate, ArrayAccess, Serializable, Countable {
      public function __construct(array|object $array = [], int $flags = 0, string $iteratorClass = ArrayIterator::class) {}
      public function offsetExists(mixed $key): bool {}
      public function offsetGet(mixed $key): mixed {}
      public function offsetSet(mixed $key, mixed $value): void {}
      public function offsetUnset(mixed $key): void {}
      public function append(mixed $value): void {}
      public function getArrayCopy(): array {}
      public function count(): int {}
      public function getIterator(): Iterator {}
      public function serialize() {}
      public function unserialize(string $data) {}
    }
    class SplDoublyLinkedList implements Iterator, Countable, ArrayAccess, Serializable {
      public function add(int $index, mixed $value): void {}
      public function pop(): mixed {}
      public function shift(): mixed {}
      public function push(mixed $value): void {}
      public function unshift(mixed $value): void {}
      public function top(): mixed {}
      public function bottom(): mixed {}
      public function isEmpty(): bool {}
      public function count(): int {}
      public function toArray(): array {}
      public function offsetExists($index): bool {}
      public function offsetGet($index): mixed {}
      public function offsetSet($index, mixed $value): void {}
      public function offsetUnset($index): void {}
      public function current(): mixed {}
      public function key(): int {}
      public function next(): void {}
      public function prev(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
      public function serialize() {}
      public function unserialize(string $data) {}
    }
    class SplQueue extends SplDoublyLinkedList {
      public function enqueue(mixed $value): void {}
      public function dequeue(): mixed {}
    }
    class SplStack extends SplDoublyLinkedList {}
    abstract class SplHeap implements Iterator, Countable {
      public function extract(): mixed {}
      public function insert(mixed $value): bool {}
      public function top(): mixed {}
      public function count(): int {}
      public function isEmpty(): bool {}
      public function current(): mixed {}
      public function key(): int {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
      abstract protected function compare(mixed $value1, mixed $value2): int {}
    }
    class SplMinHeap extends SplHeap {
      protected function compare(mixed $value1, mixed $value2): int {}
    }
    class SplMaxHeap extends SplHeap {
      protected function compare(mixed $value1, mixed $value2): int {}
    }
    class SplPriorityQueue implements Iterator, Countable {
      public function compare(mixed $priority1, mixed $priority2): int {}
      public function insert(mixed $value, mixed $priority) {}
      public function setExtractFlags(int $flags): int {}
      public function top(): mixed {}
      public function extract(): mixed {}
      public function count(): int {}
      public function isEmpty(): bool {}
      public function current(): mixed {}
      public function key(): int {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
    }
    class SplFixedArray implements IteratorAggregate, ArrayAccess, Countable, JsonSerializable {
      public function __construct(int $size = 0) {}
      public function count(): int {}
      public function toArray(): array {}
      public static function fromArray(array $array, bool $preserveKeys = true): SplFixedArray {}
      public function getSize(): int {}
      public function setSize(int $size) {}
      public function offsetExists($index): bool {}
      public function offsetGet($index): mixed {}
      public function offsetSet($index, mixed $value): void {}
      public function offsetUnset($index): void {}
      public function getIterator(): Iterator {}
      public function jsonSerialize(): array {}
    }
    class SplObjectStorage implements Countable, Iterator, Serializable, ArrayAccess {
      public function attach(object $object, mixed $info = null): void {}
      public function detach(object $object): void {}
      public function contains(object $object): bool {}
      public function addAll(SplObjectStorage $storage): int {}
      public function removeAll(SplObjectStorage $storage): int {}
      public function getInfo(): mixed {}
      public function setInfo(mixed $info): void {}
      public function count(int $mode = COUNT_NORMAL): int {}
      public function rewind(): void {}
      public function valid(): bool {}
      public function key(): int {}
      public function current(): object {}
      public function next(): void {}
      public function offsetExists($object): bool {}
      public function offsetGet($object): mixed {}
      public function offsetSet($object, mixed $info = null): void {}
      public function offsetUnset($object): void {}
      public function getHash(object $object): string {}
      public function serialize() {}
      public function unserialize(string $data) {}
    }
    class SplFileInfo implements Stringable {
      public function __construct(string $filename) {}
      public function getPath(): string {}
      public function getFilename(): string {}
      public function getExtension(): string {}
      public function getBasename(string $suffix = ""): string {}
      public function getPathname(): string {}
      public function getRealPath(): string|false {}
      public function getSize(): int|false {}
      public function getMTime(): int|false {}
      public function getType(): string|false {}
      public function isDir(): bool {}
      public function isFile(): bool {}
      public function isLink(): bool {}
      public function isReadable(): bool {}
      public function isWritable(): bool {}
      public function openFile(string $mode = "r"): SplFileObject {}
      public function __toString(): string {}
    }
    class SplFileObject extends SplFileInfo implements RecursiveIterator, SeekableIterator {
      public function __construct(string $filename, string $mode = "r", bool $useIncludePath = false, $context = null) {}
      public function eof(): bool {}
      public function fgets(): string {}
      public function fgetcsv(string $separator = ",", string $enclosure = "\"", string $escape = "\\"): array|false {}
      public function fwrite(string $data, int $length = 0): int|false {}
      public function current(): string|array|false {}
      public function key(): int {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
      public function seek(int $line): void {}
      public function hasChildren(): bool {}
      public function getChildren(): ?RecursiveIterator {}
    }
    interface RecursiveIterator extends Iterator {
      public function hasChildren(): bool {}
      public function getChildren(): ?RecursiveIterator {}
    }
    class DirectoryIterator extends SplFileInfo implements SeekableIterator {
      public function __construct(string $directory) {}
      public function isDot(): bool {}
      public function current(): mixed {}
      public function key(): mixed {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
      public function seek(int $offset): void {}
    }
    class FilesystemIterator extends DirectoryIterator {
      const SKIP_DOTS = 4096;
      const KEY_AS_PATHNAME = 0;
      const CURRENT_AS_FILEINFO = 0;
      public function __construct(string $directory, int $flags = 4096) {}
    }
    class RecursiveDirectoryIterator extends FilesystemIterator implements RecursiveIterator {
      public function __construct(string $directory, int $flags = 0) {}
      public function hasChildren(bool $allowLinks = false): bool {}
      public function getChildren(): RecursiveDirectoryIterator {}
      public function getSubPathname(): string {}
    }
    class RecursiveIteratorIterator implements OuterIterator {
      const LEAVES_ONLY = 0;
      const SELF_FIRST = 1;
      const CHILD_FIRST = 2;
      public function __construct(Traversable $iterator, int $mode = RecursiveIteratorIterator::LEAVES_ONLY, int $flags = 0) {}
      public function getDepth(): int {}
      public function getInnerIterator(): RecursiveIterator {}
      public function current(): mixed {}
      public function key(): mixed {}
      public function next(): void {}
      public function rewind(): void {}
      public function valid(): bool {}
    }

    // Dates.

    interface DateTimeInterface {
      const ATOM = "Y-m-d\\TH:i:sP";
      const ISO8601 = "Y-m-d\\TH:i:sO";
      const RFC3339 = "Y-m-d\\TH:i:sP";
      const RFC3339_EXTENDED = "Y-m-d\\TH:i:s.vP";
      const RFC2822 = "D, d M Y H:i:s O";
      const COOKIE = "l, d-M-Y H:i:s T";
      public function format(string $format): string {}
      public function getTimezone(): DateTimeZone|false {}
      public function getOffset(): int {}
      public function getTimestamp(): int {}
      public function diff(DateTimeInterface $targetObject, bool $absolute = false): DateInterval {}
    }
    class DateTime implements DateTimeInterface {
      public function __construct(string $datetime = "now", ?DateTimeZone $timezone = null) {}
      public static function createFromFormat(string $format, string $datetime, ?DateTimeZone $timezone = null): DateTime|false {}
      public static function createFromImmutable(DateTimeImmutable $object): static {}
      public static function createFromInterface(DateTimeInterface $object): static {}
      public function format(string $format): string {}
      public function modify(string $modifier): DateTime|false {}
      public function add(DateInterval $interval): DateTime {}
      public function sub(DateInterval $interval): DateTime {}
      public function setTimezone(DateTimeZone $timezone): DateTime {}
      public function setDate(int $year, int $month, int $day): DateTime {}
      public function setTime(int $hour, int $minute, int $second = 0, int $microsecond = 0): DateTime {}
      public function setTimestamp(int $timestamp): DateTime {}
      public function getTimezone(): DateTimeZone|false {}
      public function getOffset(): int {}
      public function getTimestamp(): int {}
      public function diff(DateTimeInterface $targetObject, bool $absolute = false): DateInterval {}
    }
    class DateTimeImmutable implements DateTimeInterface {
      public function __construct(string $datetime = "now", ?DateTimeZone $timezone = null) {}
      public static function createFromFormat(string $format, string $datetime, ?DateTimeZone $timezone = null): DateTimeImmutable|false {}
      public static function createFromMutable(DateTime $object): static {}
      public static function createFromInterface(DateTimeInterface $object): static {}
      public function format(string $format): string {}
      public function modify(string $modifier): DateTimeImmutable|false {}
      public function add(DateInterval $interval): DateTimeImmutable {}
      public function sub(DateInterval $interval): DateTimeImmutable {}
      public function setTimezone(DateTimeZone $timezone): DateTimeImmutable {}
      public function setDate(int $year, int $month, int $day): DateTimeImmutable {}
      public function setTime(int $hour, int $minute, int $second = 0, int $microsecond = 0): DateTimeImmutable {}
      public function setTimestamp(int $timestamp): DateTimeImmutable {}
      public function getTimezone(): DateTimeZone|false {}
      public function getOffset(): int {}
      public function getTimestamp(): int {}
      public function diff(DateTimeInterface $targetObject, bool $absolute = false): DateInterval {}
    }
    class DateTimeZone {
      const UTC = 1024;
      public function __construct(string $timezone) {}
      public function getName(): string {}
      public function getOffset(DateTimeInterface $datetime): int {}
      public static function listIdentifiers(int $timezoneGroup = 2047, ?string $countryCode = null): array {}
    }
    class DateInterval {
      public $y;
      public $m;
      public $d;
      public $h;
      public $i;
      public $s;
      public $f;
      public $invert;
      public $days;
      public function __construct(string $duration) {}
      public function format(string $format): string {}
      public static function createFromDateString(string $datetime): DateInterval|false {}
    }
    class DatePeriod implements IteratorAggregate {
      const EXCLUDE_START_DATE = 1;
      public function __construct($start, $interval = null, $end = null, $options = 0) {}
      public function getStartDate(): DateTimeInterface {}
      public function getEndDate(): ?DateTimeInterface {}
      public function getDateInterval(): DateInterval {}
      public function getIterator(): Iterator {}
    }

    // PDO.

    class PDO {
      const PARAM_NULL = 0;
      const PARAM_INT = 1;
      const PARAM_STR = 2;
      const PARAM_LOB = 3;
      const PARAM_BOOL = 5;
      const FETCH_DEFAULT = 0;
      const FETCH_ASSOC = 2;
      const FETCH_NUM = 3;
      const FETCH_BOTH = 4;
      const FETCH_OBJ = 5;
      const FETCH_CLASS = 8;
      const FETCH_COLUMN = 7;
      const ATTR_ERRMODE = 3;
      const ATTR_DEFAULT_FETCH_MODE = 19;
      const ATTR_EMULATE_PREPARES = 20;
      const ATTR_PERSISTENT = 12;
      const ERRMODE_SILENT = 0;
      const ERRMODE_WARNING = 1;
      const ERRMODE_EXCEPTION = 2;
      public function __construct(string $dsn, ?string $username = null, ?string $password = null, ?array $options = null) {}
      public function prepare(string $query, array $options = []): PDOStatement|false {}
      public function query(string $query, ?int $fetchMode = null, mixed ...$fetchModeArgs): PDOStatement|false {}
      public function exec(string $statement): int|false {}
      public function lastInsertId(?string $name = null): string|false {}
      public function beginTransaction(): bool {}
      public function commit(): bool {}
      public function rollBack(): bool {}
      public function inTransaction(): bool {}
      public function quote(string $string, int $type = PDO::PARAM_STR): string|false {}
      public function setAttribute(int $attribute, mixed $value): bool {}
      public function getAttribute(int $attribute): mixed {}
      public function errorCode(): ?string {}
      public function errorInfo(): array {}
    }
    class PDOStatement implements IteratorAggregate {
      public string $queryString;
      public function execute(?array $params = null): bool {}
      public function fetch(int $mode = PDO::FETCH_DEFAULT, int $cursorOrientation = 0, int $cursorOffset = 0): mixed {}
      public function fetchAll(int $mode = PDO::FETCH_DEFAULT, mixed ...$args): array {}
      public function fetchColumn(int $column = 0): mixed {}
      public function fetchObject(?string $class = "stdClass", array $constructorArgs = []): object|false {}
      public function bindValue(int|string $param, mixed $value, int $type = PDO::PARAM_STR): bool {}
      public function bindParam(int|string $param, mixed &$var, int $type = PDO::PARAM_STR, int $maxLength = 0, mixed $driverOptions = null): bool {}
      public function rowCount(): int {}
      public function columnCount(): int {}
      public function closeCursor(): bool {}
      public function setFetchMode(int $mode, mixed ...$args) {}
      public function errorCode(): ?string {}
      public function errorInfo(): array {}
      public function getIterator(): Iterator {}
    }
    class PDOException extends RuntimeException {
      public ?array $errorInfo = null;
    }

    // Reflection, most used.

    class ReflectionClass implements Stringable {
      public string $name;
      public function __construct(object|string $objectOrClass) {}
      public function getName(): string {}
      public function getShortName(): string {}
      public function getNamespaceName(): string {}
      public function getParentClass(): ReflectionClass|false {}
      public function getMethods(?int $filter = null): array {}
      public function getMethod(string $name): ReflectionMethod {}
      public function getProperties(?int $filter = null): array {}
      public function getProperty(string $name): ReflectionProperty {}
      public function getConstants(?int $filter = null): array {}
      public function getAttributes(?string $name = null, int $flags = 0): array {}
      public function getConstructor(): ?ReflectionMethod {}
      public function hasMethod(string $name): bool {}
      public function hasProperty(string $name): bool {}
      public function implementsInterface(ReflectionClass|string $interface): bool {}
      public function isSubclassOf(ReflectionClass|string $class): bool {}
      public function isInterface(): bool {}
      public function isAbstract(): bool {}
      public function isFinal(): bool {}
      public function isInstantiable(): bool {}
      public function newInstance(mixed ...$args): object {}
      public function newInstanceArgs(array $args = []): ?object {}
      public function newInstanceWithoutConstructor(): object {}
      public function getFileName(): string|false {}
      public function getDocComment(): string|false {}
      public function __toString(): string {}
    }
    abstract class ReflectionFunctionAbstract implements Stringable {
      public string $name;
      public function getName(): string {}
      public function getParameters(): array {}
      public function getNumberOfParameters(): int {}
      public function getReturnType(): ?ReflectionType {}
      public function getDocComment(): string|false {}
      public function getAttributes(?string $name = null, int $flags = 0): array {}
    }
    class ReflectionFunction extends ReflectionFunctionAbstract {
      public function __construct(Closure|string $function) {}
      public function invoke(mixed ...$args): mixed {}
      public function invokeArgs(array $args = []): mixed {}
      public function __toString(): string {}
    }
    class ReflectionMethod extends ReflectionFunctionAbstract {
      public string $class;
      public function __construct(object|string $objectOrMethod, ?string $method = null) {}
      public function invoke(?object $object, mixed ...$args): mixed {}
      public function invokeArgs(?object $object, array $args = []): mixed {}
      public function setAccessible(bool $accessible): void {}
      public function isPublic(): bool {}
      public function isStatic(): bool {}
      public function getDeclaringClass(): ReflectionClass {}
      public function __toString(): string {}
    }
    class ReflectionProperty implements Stringable {
      public string $name;
      public string $class;
      public function __construct(object|string $class, string $property) {}
      public function getName(): string {}
      public function getValue(?object $object = null): mixed {}
      public function setValue(mixed $objectOrValue, mixed $value = null): void {}
      public function setAccessible(bool $accessible): void {}
      public function getType(): ?ReflectionType {}
      public function isPublic(): bool {}
      public function isStatic(): bool {}
      public function getDocComment(): string|false {}
      public function getAttributes(?string $name = null, int $flags = 0): array {}
      public function __toString(): string {}
    }
    class ReflectionParameter implements Stringable {
      public string $name;
      public function getName(): string {}
      public function getType(): ?ReflectionType {}
      public function getPosition(): int {}
      public function isOptional(): bool {}
      public function isDefaultValueAvailable(): bool {}
      public function getDefaultValue(): mixed {}
      public function __toString(): string {}
    }
    abstract class ReflectionType implements Stringable {
      public function allowsNull(): bool {}
      public function __toString(): string {}
    }
    class ReflectionNamedType extends ReflectionType {
      public function getName(): string {}
      public function isBuiltin(): bool {}
    }
    class ReflectionAttribute {
      public function getName(): string {}
      public function getArguments(): array {}
      public function newInstance(): object {}
    }
    class ReflectionEnum extends ReflectionClass {
      public function getCases(): array {}
    }

    // Functions: strings.

    function strlen(string $string): int {}
    function str_contains(string $haystack, string $needle): bool {}
    function str_starts_with(string $haystack, string $needle): bool {}
    function str_ends_with(string $haystack, string $needle): bool {}
    function str_replace(array|string $search, array|string $replace, string|array $subject, &$count = null): string|array {}
    function str_ireplace(array|string $search, array|string $replace, string|array $subject, &$count = null): string|array {}
    function str_repeat(string $string, int $times): string {}
    function str_pad(string $string, int $length, string $pad_string = " ", int $pad_type = STR_PAD_RIGHT): string {}
    function str_split(string $string, int $length = 1): array {}
    function str_word_count(string $string, int $format = 0, ?string $characters = null): array|int {}
    function strrev(string $string): string {}
    function strpos(string $haystack, string $needle, int $offset = 0): int|false {}
    function stripos(string $haystack, string $needle, int $offset = 0): int|false {}
    function strrpos(string $haystack, string $needle, int $offset = 0): int|false {}
    function strstr(string $haystack, string $needle, bool $before_needle = false): string|false {}
    function strrchr(string $haystack, string $needle): string|false {}
    function substr(string $string, int $offset, ?int $length = null): string {}
    function substr_count(string $haystack, string $needle, int $offset = 0, ?int $length = null): int {}
    function substr_replace(array|string $string, array|string $replace, array|int $offset, array|int|null $length = null): string|array {}
    function strtolower(string $string): string {}
    function strtoupper(string $string): string {}
    function ucfirst(string $string): string {}
    function lcfirst(string $string): string {}
    function ucwords(string $string, string $separators = " \t\r\n\f\v"): string {}
    function trim(string $string, string $characters = " \n\r\t\v\x00"): string {}
    function ltrim(string $string, string $characters = " \n\r\t\v\x00"): string {}
    function rtrim(string $string, string $characters = " \n\r\t\v\x00"): string {}
    function chop(string $string, string $characters = " \n\r\t\v\x00"): string {}
    function strcmp(string $string1, string $string2): int {}
    function strcasecmp(string $string1, string $string2): int {}
    function strncmp(string $string1, string $string2, int $length): int {}
    function strncasecmp(string $string1, string $string2, int $length): int {}
    function strnatcmp(string $string1, string $string2): int {}
    function strnatcasecmp(string $string1, string $string2): int {}
    function strtr(string $string, $from, ?string $to = null): string {}
    function sprintf(string $format, mixed ...$values): string {}
    function vsprintf(string $format, array $values): string {}
    function printf(string $format, mixed ...$values): int {}
    function fprintf($stream, string $format, mixed ...$values): int {}
    function number_format(float $num, int $decimals = 0, ?string $decimal_separator = ".", ?string $thousands_separator = ","): string {}
    function implode(array|string $separator, ?array $array = null): string {}
    function join(array|string $separator, ?array $array = null): string {}
    function explode(string $separator, string $string, int $limit = PHP_INT_MAX): array {}
    function nl2br(string $string, bool $use_xhtml = true): string {}
    function htmlspecialchars(string $string, int $flags = ENT_QUOTES, ?string $encoding = null, bool $double_encode = true): string {}
    function htmlspecialchars_decode(string $string, int $flags = ENT_QUOTES): string {}
    function htmlentities(string $string, int $flags = ENT_QUOTES, ?string $encoding = null, bool $double_encode = true): string {}
    function html_entity_decode(string $string, int $flags = ENT_QUOTES, ?string $encoding = null): string {}
    function strip_tags(string $string, array|string|null $allowed_tags = null): string {}
    function addslashes(string $string): string {}
    function stripslashes(string $string): string {}
    function wordwrap(string $string, int $width = 75, string $break = "\n", bool $cut_long_words = false): string {}
    function chr(int $codepoint): string {}
    function ord(string $character): int {}
    function lcg_value(): float {}
    function nl_langinfo(int $item): string|false {}
    function sha1(string $string, bool $binary = false): string {}
    function md5(string $string, bool $binary = false): string {}
    function crc32(string $string): int {}
    function hash(string $algo, string $data, bool $binary = false, array $options = []): string {}
    function hash_hmac(string $algo, string $data, string $key, bool $binary = false): string {}
    function hash_equals(string $known_string, string $user_string): bool {}
    function base64_encode(string $string): string {}
    function base64_decode(string $string, bool $strict = false): string|false {}
    function bin2hex(string $string): string {}
    function hex2bin(string $string): string|false {}
    function dechex(int $num): string {}
    function hexdec(string $hex_string): int|float {}
    function decbin(int $num): string {}
    function bindec(string $binary_string): int|float {}
    function pack(string $format, mixed ...$values): string {}
    function unpack(string $format, string $string, int $offset = 0): array|false {}
    function uniqid(string $prefix = "", bool $more_entropy = false): string {}
    function urlencode(string $string): string {}
    function urldecode(string $string): string {}
    function rawurlencode(string $string): string {}
    function rawurldecode(string $string): string {}
    function http_build_query(array|object $data, string $numeric_prefix = "", ?string $arg_separator = null, int $encoding_type = PHP_QUERY_RFC1738): string {}
    function parse_str(string $string, &$result): void {}
    function parse_url(string $url, int $component = -1): int|string|array|null|false {}
    function mb_strlen(string $string, ?string $encoding = null): int {}
    function mb_substr(string $string, int $start, ?int $length = null, ?string $encoding = null): string {}
    function mb_strpos(string $haystack, string $needle, int $offset = 0, ?string $encoding = null): int|false {}
    function mb_strtolower(string $string, ?string $encoding = null): string {}
    function mb_strtoupper(string $string, ?string $encoding = null): string {}
    function mb_str_split(string $string, int $length = 1, ?string $encoding = null): array {}
    function mb_convert_encoding(array|string $string, string $to_encoding, array|string|null $from_encoding = null): array|string|false {}
    function mb_internal_encoding(?string $encoding = null): string|bool {}
    function iconv(string $from_encoding, string $to_encoding, string $string): string|false {}
    function ctype_digit(mixed $text): bool {}
    function ctype_alpha(mixed $text): bool {}
    function ctype_alnum(mixed $text): bool {}
    function ctype_space(mixed $text): bool {}
    function ctype_upper(mixed $text): bool {}
    function ctype_lower(mixed $text): bool {}
    function preg_match(string $pattern, string $subject, &$matches = null, int $flags = 0, int $offset = 0): int|false {}
    function preg_match_all(string $pattern, string $subject, &$matches = null, int $flags = 0, int $offset = 0): int|false {}
    function preg_replace(string|array $pattern, string|array $replacement, string|array $subject, int $limit = -1, &$count = null): string|array|null {}
    function preg_replace_callback(string|array $pattern, callable $callback, string|array $subject, int $limit = -1, &$count = null, int $flags = 0): string|array|null {}
    function preg_split(string $pattern, string $subject, int $limit = -1, int $flags = 0): array|false {}
    function preg_quote(string $str, ?string $delimiter = null): string {}
    function preg_grep(string $pattern, array $array, int $flags = 0): array|false {}
    function preg_last_error(): int {}
    function preg_last_error_msg(): string {}
    function json_encode(mixed $value, int $flags = 0, int $depth = 512): string|false {}
    function json_decode(string $json, ?bool $associative = null, int $depth = 512, int $flags = 0): mixed {}
    function json_last_error(): int {}
    function json_last_error_msg(): string {}
    function json_validate(string $json, int $depth = 512, int $flags = 0): bool {}
    function serialize(mixed $value): string {}
    function unserialize(string $data, array $options = []): mixed {}
    function var_dump(mixed $value, mixed ...$values): void {}
    function var_export(mixed $value, bool $return = false): ?string {}
    function print_r(mixed $value, bool $return = false): string|bool {}
    function password_hash(string $password, string|int|null $algo, array $options = []): string {}
    function password_verify(string $password, string $hash): bool {}
    function password_needs_rehash(string $hash, string|int|null $algo, array $options = []): bool {}
    function random_bytes(int $length): string {}
    function random_int(int $min, int $max): int {}
    function rand(int $min = 0, int $max = PHP_INT_MAX): int {}
    function mt_rand(int $min = 0, int $max = PHP_INT_MAX): int {}
    function mt_srand(int $seed = 0, int $mode = MT_RAND_MT19937): void {}
    function version_compare(string $version1, string $version2, ?string $operator = null): int|bool {}

    // Functions: arrays.

    function count(Countable|array $value, int $mode = COUNT_NORMAL): int {}
    function sizeof(Countable|array $value, int $mode = COUNT_NORMAL): int {}
    function in_array(mixed $needle, array $haystack, bool $strict = false): bool {}
    function array_key_exists($key, array $array): bool {}
    function key_exists($key, array $array): bool {}
    function array_keys(array $array, mixed $filter_value = null, bool $strict = false): array {}
    function array_values(array $array): array {}
    function array_merge(array ...$arrays): array {}
    function array_merge_recursive(array ...$arrays): array {}
    function array_replace(array $array, array ...$replacements): array {}
    function array_combine(array $keys, array $values): array {}
    function array_flip(array $array): array {}
    function array_fill(int $start_index, int $count, mixed $value): array {}
    function array_fill_keys(array $keys, mixed $value): array {}
    function array_pad(array $array, int $length, mixed $value): array {}
    function array_map(?callable $callback, array $array, array ...$arrays): array {}
    function array_filter(array $array, ?callable $callback = null, int $mode = 0): array {}
    function array_reduce(array $array, callable $callback, mixed $initial = null): mixed {}
    function array_walk(array|object &$array, callable $callback, mixed $arg = null): bool {}
    function array_search(mixed $needle, array $haystack, bool $strict = false): int|string|false {}
    function array_slice(array $array, int $offset, ?int $length = null, bool $preserve_keys = false): array {}
    function array_splice(array &$array, int $offset, ?int $length = null, mixed $replacement = []): array {}
    function array_push(array &$array, mixed ...$values): int {}
    function array_pop(array &$array): mixed {}
    function array_shift(array &$array): mixed {}
    function array_unshift(array &$array, mixed ...$values): int {}
    function array_unique(array $array, int $flags = SORT_STRING): array {}
    function array_reverse(array $array, bool $preserve_keys = false): array {}
    function array_column(array $array, int|string|null $column_key, int|string|null $index_key = null): array {}
    function array_chunk(array $array, int $length, bool $preserve_keys = false): array {}
    function array_diff(array $array, array ...$arrays): array {}
    function array_diff_key(array $array, array ...$arrays): array {}
    function array_diff_assoc(array $array, array ...$arrays): array {}
    function array_intersect(array $array, array ...$arrays): array {}
    function array_intersect_key(array $array, array ...$arrays): array {}
    function array_sum(array $array): int|float {}
    function array_product(array $array): int|float {}
    function array_rand(array $array, int $num = 1): int|string|array {}
    function array_count_values(array $array): array {}
    function array_key_first(array $array): int|string|null {}
    function array_key_last(array $array): int|string|null {}
    function array_is_list(array $array): bool {}
    function array_find(array $array, callable $callback): mixed {}
    function array_any(array $array, callable $callback): bool {}
    function array_all(array $array, callable $callback): bool {}
    function sort(array &$array, int $flags = SORT_REGULAR): bool {}
    function rsort(array &$array, int $flags = SORT_REGULAR): bool {}
    function usort(array &$array, callable $callback): bool {}
    function uasort(array &$array, callable $callback): bool {}
    function uksort(array &$array, callable $callback): bool {}
    function asort(array &$array, int $flags = SORT_REGULAR): bool {}
    function arsort(array &$array, int $flags = SORT_REGULAR): bool {}
    function ksort(array &$array, int $flags = SORT_REGULAR): bool {}
    function krsort(array &$array, int $flags = SORT_REGULAR): bool {}
    function shuffle(array &$array): bool {}
    function range($start, $end, int|float $step = 1): array {}
    function compact($var_name, ...$var_names): array {}
    function extract(array &$array, int $flags = EXTR_OVERWRITE, string $prefix = ""): int {}
    function current(array|object $array): mixed {}
    function key(array|object $array): int|string|null {}
    function next(array|object &$array): mixed {}
    function prev(array|object &$array): mixed {}
    function reset(array|object &$array): mixed {}
    function end(array|object &$array): mixed {}
    function iterator_to_array(Traversable|array $iterator, bool $preserve_keys = true): array {}
    function iterator_count(Traversable|array $iterator): int {}
    function iterator_apply(Traversable $iterator, callable $callback, ?array $args = null): int {}

    // Functions: types, classes and functions.

    function is_array(mixed $value): bool {}
    function is_string(mixed $value): bool {}
    function is_int(mixed $value): bool {}
    function is_integer(mixed $value): bool {}
    function is_float(mixed $value): bool {}
    function is_bool(mixed $value): bool {}
    function is_numeric(mixed $value): bool {}
    function is_null(mixed $value): bool {}
    function is_object(mixed $value): bool {}
    function is_callable(mixed $value, bool $syntax_only = false, &$callable_name = null): bool {}
    function is_iterable(mixed $value): bool {}
    function is_countable(mixed $value): bool {}
    function is_resource(mixed $value): bool {}
    function is_scalar(mixed $value): bool {}
    function is_a(mixed $object_or_class, string $class, bool $allow_string = false): bool {}
    function is_subclass_of(mixed $object_or_class, string $class, bool $allow_string = true): bool {}
    function intval(mixed $value, int $base = 10): int {}
    function floatval(mixed $value): float {}
    function boolval(mixed $value): bool {}
    function strval(mixed $value): string {}
    function settype(mixed &$var, string $type): bool {}
    function gettype(mixed $value): string {}
    function get_debug_type(mixed $value): string {}
    function get_class(object $object): string {}
    function get_parent_class(object|string $object_or_class): string|false {}
    function get_called_class(): string {}
    function get_object_vars(object $object): array {}
    function get_class_methods(object|string $object_or_class): array {}
    function class_exists(string $class, bool $autoload = true): bool {}
    function interface_exists(string $interface, bool $autoload = true): bool {}
    function trait_exists(string $trait, bool $autoload = true): bool {}
    function enum_exists(string $enum, bool $autoload = true): bool {}
    function function_exists(string $function): bool {}
    function method_exists($object_or_class, string $method): bool {}
    function property_exists($object_or_class, string $property): bool {}
    function class_implements($object_or_class, bool $autoload = true): array|false {}
    function spl_autoload_register(?callable $callback = null, bool $throw = true, bool $prepend = false): bool {}
    function spl_object_id(object $object): int {}
    function spl_object_hash(object $object): string {}
    function call_user_func(callable $callback, mixed ...$args): mixed {}
    function call_user_func_array(callable $callback, array $args): mixed {}
    function func_get_args(): array {}
    function func_num_args(): int {}
    function define(string $constant_name, mixed $value, bool $case_insensitive = false): bool {}
    function defined(string $constant_name): bool {}
    function constant(string $name): mixed {}

    // Functions: math.

    function abs(int|float $num): int|float {}
    function max(mixed $value, mixed ...$values): mixed {}
    function min(mixed $value, mixed ...$values): mixed {}
    function floor(int|float $num): float {}
    function ceil(int|float $num): float {}
    function round(int|float $num, int $precision = 0, int $mode = PHP_ROUND_HALF_UP): float {}
    function intdiv(int $num1, int $num2): int {}
    function fmod(float $num1, float $num2): float {}
    function fdiv(float $num1, float $num2): float {}
    function pow(mixed $num, mixed $exponent): int|float|object {}
    function sqrt(float $num): float {}
    function exp(float $num): float {}
    function log(float $num, float $base = M_E): float {}
    function log10(float $num): float {}
    function sin(float $num): float {}
    function cos(float $num): float {}
    function tan(float $num): float {}
    function pi(): float {}
    function is_nan(float $num): bool {}
    function is_finite(float $num): bool {}
    function is_infinite(float $num): bool {}

    // Functions: files, streams and output.

    function file_get_contents(string $filename, bool $use_include_path = false, $context = null, int $offset = 0, ?int $length = null): string|false {}
    function file_put_contents(string $filename, mixed $data, int $flags = 0, $context = null): int|false {}
    function file(string $filename, int $flags = 0, $context = null): array|false {}
    function file_exists(string $filename): bool {}
    function is_file(string $filename): bool {}
    function is_dir(string $filename): bool {}
    function is_link(string $filename): bool {}
    function is_readable(string $filename): bool {}
    function is_writable(string $filename): bool {}
    function is_executable(string $filename): bool {}
    function filesize(string $filename): int|false {}
    function filemtime(string $filename): int|false {}
    function mkdir(string $directory, int $permissions = 0777, bool $recursive = false, $context = null): bool {}
    function rmdir(string $directory, $context = null): bool {}
    function unlink(string $filename, $context = null): bool {}
    function rename(string $from, string $to, $context = null): bool {}
    function copy(string $from, string $to, $context = null): bool {}
    function touch(string $filename, ?int $mtime = null, ?int $atime = null): bool {}
    function chmod(string $filename, int $permissions): bool {}
    function realpath(string $path): string|false {}
    function basename(string $path, string $suffix = ""): string {}
    function dirname(string $path, int $levels = 1): string {}
    function pathinfo(string $path, int $flags = PATHINFO_ALL): array|string {}
    function glob(string $pattern, int $flags = 0): array|false {}
    function scandir(string $directory, int $sorting_order = SCANDIR_SORT_ASCENDING, $context = null): array|false {}
    function tempnam(string $directory, string $prefix): string|false {}
    function tmpfile() {}
    function sys_get_temp_dir(): string {}
    function getcwd(): string|false {}
    function chdir(string $directory): bool {}
    function fopen(string $filename, string $mode, bool $use_include_path = false, $context = null) {}
    function fclose($stream): bool {}
    function fread($stream, int $length): string|false {}
    function fwrite($stream, string $data, ?int $length = null): int|false {}
    function fputs($stream, string $data, ?int $length = null): int|false {}
    function fgets($stream, ?int $length = null): string|false {}
    function fgetcsv($stream, ?int $length = null, string $separator = ",", string $enclosure = "\"", string $escape = "\\"): array|false {}
    function fputcsv($stream, array $fields, string $separator = ",", string $enclosure = "\"", string $escape = "\\", string $eol = "\n"): int|false {}
    function feof($stream): bool {}
    function fflush($stream): bool {}
    function fseek($stream, int $offset, int $whence = SEEK_SET): int {}
    function ftell($stream): int|false {}
    function rewind($stream): bool {}
    function flock($stream, int $operation, &$would_block = null): bool {}
    function stream_get_contents($stream, ?int $length = null, int $offset = -1): string|false {}
    function stream_context_create(?array $options = null, ?array $params = null) {}
    function stream_socket_server(string $address, &$error_code = null, &$error_message = null, int $flags = 12, $context = null) {}
    function stream_socket_client(string $address, &$error_code = null, &$error_message = null, ?float $timeout = null, int $flags = 4, $context = null) {}
    function stream_socket_accept($socket, ?float $timeout = null, &$peer_name = null) {}
    function stream_socket_get_name($socket, bool $remote): string|false {}
    function stream_set_timeout($stream, int $seconds, int $microseconds = 0): bool {}
    function stream_get_meta_data($stream): array {}
    function proc_get_status($process): array {}
    function proc_terminate($process, int $signal = 15): bool {}
    function array_walk_recursive(array|object &$array, callable $callback, mixed $arg = null): bool {}
    function stream_set_blocking($stream, bool $enable): bool {}
    function stream_select(?array &$read, ?array &$write, ?array &$except, ?int $seconds, ?int $microseconds = null): int|false {}
    function readline(?string $prompt = null): string|false {}
    function ob_start($callback = null, int $chunk_size = 0, int $flags = PHP_OUTPUT_HANDLER_STDFLAGS): bool {}
    function ob_get_clean(): string|false {}
    function ob_get_contents(): string|false {}
    function ob_end_clean(): bool {}
    function ob_end_flush(): bool {}
    function flush(): void {}
    function header(string $header, bool $replace = true, int $response_code = 0): void {}
    function headers_sent(&$filename = null, &$line = null): bool {}
    function http_response_code(int $response_code = 0): int|bool {}
    function setcookie(string $name, string $value = "", array|int $expires_or_options = 0, string $path = "", string $domain = "", bool $secure = false, bool $httponly = false): bool {}
    function session_start(array $options = []): bool {}
    function session_id(?string $id = null): string|false {}
    function session_destroy(): bool {}
    function session_regenerate_id(bool $delete_old_session = false): bool {}
    function filter_var(mixed $value, int $filter = FILTER_DEFAULT, array|int $options = 0): mixed {}
    function filter_input(int $type, string $var_name, int $filter = FILTER_DEFAULT, array|int $options = 0): mixed {}

    // Functions: runtime, time and errors.

    function time(): int {}
    function microtime(bool $as_float = false): string|float {}
    function hrtime(bool $as_number = false): array|int|float|false {}
    function date(string $format, ?int $timestamp = null): string {}
    function gmdate(string $format, ?int $timestamp = null): string {}
    function mktime(int $hour, ?int $minute = null, ?int $second = null, ?int $month = null, ?int $day = null, ?int $year = null): int|false {}
    function strtotime(string $datetime, ?int $baseTimestamp = null): int|false {}
    function checkdate(int $month, int $day, int $year): bool {}
    function date_default_timezone_set(string $timezoneId): bool {}
    function date_default_timezone_get(): string {}
    function sleep(int $seconds): int {}
    function usleep(int $microseconds): void {}
    function set_time_limit(int $seconds): bool {}
    function getenv(?string $name = null, bool $local_only = false): array|string|false {}
    function putenv(string $assignment): bool {}
    function ini_set(string $option, $value): string|false {}
    function ini_get(string $option): string|false {}
    function error_reporting(?int $error_level = null): int {}
    function error_log(string $message, int $message_type = 0, ?string $destination = null, ?string $additional_headers = null): bool {}
    function trigger_error(string $message, int $error_level = E_USER_NOTICE): bool {}
    function user_error(string $message, int $error_level = E_USER_NOTICE): bool {}
    function set_error_handler(?callable $callback, int $error_levels = E_ALL) {}
    function restore_error_handler(): bool {}
    function set_exception_handler(?callable $callback) {}
    function register_shutdown_function(callable $callback, mixed ...$args): void {}
    function debug_backtrace(int $options = DEBUG_BACKTRACE_PROVIDE_OBJECT, int $limit = 0): array {}
    function debug_print_backtrace(int $options = 0, int $limit = 0): void {}
    function error_get_last(): ?array {}
    function memory_get_usage(bool $real_usage = false): int {}
    function memory_get_peak_usage(bool $real_usage = false): int {}
    function gc_collect_cycles(): int {}
    function phpversion(?string $extension = null): string|false {}
    function php_sapi_name(): string|false {}
    function php_uname(string $mode = "a"): string {}
    function extension_loaded(string $extension): bool {}
    function getmypid(): int|false {}
    function gethostname(): string|false {}
    function spl_autoload_functions(): array {}
    function exec(string $command, &$output = null, &$result_code = null): string|false {}
    function shell_exec(string $command): string|false|null {}
    function system(string $command, &$result_code = null): string|false {}
    function passthru(string $command, &$result_code = null): ?bool {}
    function escapeshellarg(string $arg): string {}
    function escapeshellcmd(string $command): string {}
    function proc_open($command, array $descriptor_spec, &$pipes, ?string $cwd = null, ?array $env_vars = null, ?array $options = null) {}
    function proc_close($process): int {}
    function cli_set_process_title(string $title): bool {}
    function assert(mixed $assertion, $description = null): bool {}
    function gethostbyname(string $hostname): string {}
    function mail(string $to, string $subject, string $message, array|string $additional_headers = [], string $additional_params = ""): bool {}

    // Constants.

    const PHP_EOL = "\n";
    const PHP_INT_MAX = 9223372036854775807;
    const PHP_INT_MIN = -9223372036854775808;
    const PHP_INT_SIZE = 8;
    const PHP_FLOAT_EPSILON = 2.220446049250313E-16;
    const PHP_FLOAT_MAX = 1.7976931348623157E+308;
    const PHP_FLOAT_MIN = 2.2250738585072014E-308;
    const PHP_VERSION = "8.4.0";
    const PHP_MAJOR_VERSION = 8;
    const PHP_MINOR_VERSION = 4;
    const PHP_VERSION_ID = 80400;
    const PHP_OS = "Darwin";
    const PHP_OS_FAMILY = "Darwin";
    const PHP_SAPI = "cli";
    const PHP_BINARY = "";
    const PHP_ROUND_HALF_UP = 1;
    const PHP_ROUND_HALF_DOWN = 2;
    const PHP_ROUND_HALF_EVEN = 3;
    const PHP_QUERY_RFC1738 = 1;
    const PHP_QUERY_RFC3986 = 2;
    const PHP_OUTPUT_HANDLER_STDFLAGS = 112;
    const DIRECTORY_SEPARATOR = "/";
    const PATH_SEPARATOR = ":";
    const E_ERROR = 1;
    const E_WARNING = 2;
    const E_PARSE = 4;
    const E_NOTICE = 8;
    const E_STRICT = 2048;
    const E_DEPRECATED = 8192;
    const E_USER_ERROR = 256;
    const E_USER_WARNING = 512;
    const E_USER_NOTICE = 1024;
    const E_USER_DEPRECATED = 16384;
    const E_RECOVERABLE_ERROR = 4096;
    const E_ALL = 32767;
    const JSON_HEX_TAG = 1;
    const JSON_HEX_AMP = 2;
    const JSON_HEX_APOS = 4;
    const JSON_HEX_QUOT = 8;
    const JSON_FORCE_OBJECT = 16;
    const JSON_NUMERIC_CHECK = 32;
    const JSON_UNESCAPED_SLASHES = 64;
    const JSON_PRETTY_PRINT = 128;
    const JSON_UNESCAPED_UNICODE = 256;
    const JSON_PARTIAL_OUTPUT_ON_ERROR = 512;
    const JSON_PRESERVE_ZERO_FRACTION = 1024;
    const JSON_OBJECT_AS_ARRAY = 1;
    const JSON_BIGINT_AS_STRING = 2;
    const JSON_INVALID_UTF8_IGNORE = 1048576;
    const JSON_INVALID_UTF8_SUBSTITUTE = 2097152;
    const JSON_THROW_ON_ERROR = 4194304;
    const JSON_ERROR_NONE = 0;
    const ENT_QUOTES = 3;
    const ENT_COMPAT = 2;
    const ENT_NOQUOTES = 0;
    const ENT_HTML5 = 48;
    const ENT_SUBSTITUTE = 8;
    const SORT_REGULAR = 0;
    const SORT_NUMERIC = 1;
    const SORT_STRING = 2;
    const SORT_NATURAL = 6;
    const SORT_FLAG_CASE = 8;
    const COUNT_NORMAL = 0;
    const COUNT_RECURSIVE = 1;
    const ARRAY_FILTER_USE_KEY = 2;
    const ARRAY_FILTER_USE_BOTH = 1;
    const EXTR_OVERWRITE = 0;
    const EXTR_SKIP = 1;
    const STR_PAD_RIGHT = 1;
    const STR_PAD_LEFT = 0;
    const STR_PAD_BOTH = 2;
    const PREG_PATTERN_ORDER = 1;
    const PREG_SET_ORDER = 2;
    const PREG_OFFSET_CAPTURE = 256;
    const PREG_SPLIT_NO_EMPTY = 1;
    const PREG_SPLIT_DELIM_CAPTURE = 2;
    const PREG_UNMATCHED_AS_NULL = 512;
    const FILTER_DEFAULT = 516;
    const FILTER_VALIDATE_INT = 257;
    const FILTER_VALIDATE_BOOLEAN = 258;
    const FILTER_VALIDATE_BOOL = 258;
    const FILTER_VALIDATE_FLOAT = 259;
    const FILTER_VALIDATE_EMAIL = 274;
    const FILTER_VALIDATE_URL = 273;
    const FILTER_VALIDATE_IP = 275;
    const FILTER_NULL_ON_FAILURE = 134217728;
    const FILTER_FLAG_IPV4 = 1048576;
    const FILTER_FLAG_IPV6 = 2097152;
    const INPUT_GET = 1;
    const INPUT_POST = 0;
    const INPUT_COOKIE = 2;
    const INPUT_SERVER = 5;
    const INPUT_ENV = 4;
    const FILE_APPEND = 8;
    const FILE_IGNORE_NEW_LINES = 2;
    const FILE_SKIP_EMPTY_LINES = 4;
    const FILE_USE_INCLUDE_PATH = 1;
    const LOCK_SH = 1;
    const LOCK_EX = 2;
    const LOCK_UN = 3;
    const LOCK_NB = 4;
    const SEEK_SET = 0;
    const SEEK_CUR = 1;
    const SEEK_END = 2;
    const GLOB_BRACE = 1024;
    const GLOB_ONLYDIR = 8192;
    const GLOB_MARK = 2;
    const GLOB_NOSORT = 4;
    const PATHINFO_DIRNAME = 1;
    const PATHINFO_BASENAME = 2;
    const PATHINFO_EXTENSION = 4;
    const PATHINFO_FILENAME = 8;
    const PATHINFO_ALL = 15;
    const SCANDIR_SORT_ASCENDING = 0;
    const SCANDIR_SORT_DESCENDING = 1;
    const DEBUG_BACKTRACE_PROVIDE_OBJECT = 1;
    const DEBUG_BACKTRACE_IGNORE_ARGS = 2;
    const MT_RAND_MT19937 = 0;
    const M_PI = 3.14159265358979323846;
    const M_E = 2.7182818284590452354;
    const NAN = NAN;
    const INF = INF;
    const PASSWORD_DEFAULT = "2y";
    const PASSWORD_BCRYPT = "2y";
    const PASSWORD_ARGON2I = "argon2i";
    const PASSWORD_ARGON2ID = "argon2id";
    const STDIN = 0;
    const STDOUT = 1;
    const STDERR = 2;
    const LC_ALL = 0;
    const SIGINT = 2;
    const SIGTERM = 15;
    const SIGKILL = 9;
    const SIGHUP = 1;
    const SIGUSR1 = 30;
    const SIGUSR2 = 31;
    """#
}
