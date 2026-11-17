/// The platform's most used classes as declarations without bodies, for when no JDK sources (`src.zip`) or Android
/// SDK are on disk: what `java.lang`, `java.util`, `java.util.function`, `java.util.stream`, `java.io`, `java.nio`,
/// `java.time` and `java.util.concurrent` declare that code calls most, with the JDK's names, parameters and generics.
/// Written to `$TMPDIR/code-java-std/` when one is opened. Hand-written; extend it as needed.
enum JavaStd {
  static let files: [String: String] = [
    "java/lang/Object.java": """
      package java.lang;
      public class Object {
          public Object() {}
          public final native Class<?> getClass();
          public native int hashCode();
          public boolean equals(Object obj);
          protected native Object clone() throws CloneNotSupportedException;
          public String toString();
          public final native void notify();
          public final native void notifyAll();
          public final void wait() throws InterruptedException;
          public final void wait(long timeoutMillis) throws InterruptedException;
      }
      """,
    "java/lang/lang.java": """
      package java.lang;
      import java.lang.annotation.*;
      import java.util.*;
      import java.util.function.*;
      import java.util.stream.*;
      import java.io.*;
      import java.nio.charset.Charset;
      public interface CharSequence {
          int length();
          char charAt(int index);
          CharSequence subSequence(int start, int end);
          String toString();
          default boolean isEmpty();
          default IntStream chars();
      }
      public interface Comparable<T> { int compareTo(T o); }
      public interface Iterable<T> {
          Iterator<T> iterator();
          default void forEach(Consumer<? super T> action);
      }
      public interface AutoCloseable { void close() throws Exception; }
      @FunctionalInterface public interface Runnable { void run(); }
      public interface Appendable {
          Appendable append(CharSequence csq) throws IOException;
          Appendable append(char c) throws IOException;
      }
      public final class String implements java.io.Serializable, Comparable<String>, CharSequence {
          public static final Comparator<String> CASE_INSENSITIVE_ORDER;
          public String() {}
          public String(String original) {}
          public String(char[] value) {}
          public String(byte[] bytes) {}
          public String(byte[] bytes, Charset charset) {}
          public String(byte[] bytes, int offset, int length, Charset charset) {}
          public String(char[] value, int offset, int count) {}
          public int length();
          public boolean isEmpty();
          public boolean isBlank();
          public char charAt(int index);
          public int codePointAt(int index);
          public byte[] getBytes();
          public byte[] getBytes(Charset charset);
          public boolean equals(Object anObject);
          public boolean equalsIgnoreCase(String anotherString);
          public int compareTo(String anotherString);
          public int compareToIgnoreCase(String str);
          public boolean startsWith(String prefix);
          public boolean startsWith(String prefix, int toffset);
          public boolean endsWith(String suffix);
          public int hashCode();
          public int indexOf(int ch);
          public int indexOf(String str);
          public int indexOf(String str, int fromIndex);
          public int lastIndexOf(int ch);
          public int lastIndexOf(String str);
          public String substring(int beginIndex);
          public String substring(int beginIndex, int endIndex);
          public CharSequence subSequence(int beginIndex, int endIndex);
          public String concat(String str);
          public String replace(char oldChar, char newChar);
          public String replace(CharSequence target, CharSequence replacement);
          public String replaceAll(String regex, String replacement);
          public String replaceFirst(String regex, String replacement);
          public boolean matches(String regex);
          public boolean contains(CharSequence s);
          public String[] split(String regex);
          public String[] split(String regex, int limit);
          public static String join(CharSequence delimiter, CharSequence... elements);
          public static String join(CharSequence delimiter, Iterable<? extends CharSequence> elements);
          public String toLowerCase(Locale locale);
          public String toLowerCase();
          public String toUpperCase(Locale locale);
          public String toUpperCase();
          public String trim();
          public String strip();
          public String repeat(int count);
          public Stream<String> lines();
          public String toString();
          public char[] toCharArray();
          public IntStream chars();
          public String formatted(Object... args);
          public static String format(String format, Object... args);
          public static String valueOf(Object obj);
          public static String valueOf(char[] data);
          public static String valueOf(boolean b);
          public static String valueOf(char c);
          public static String valueOf(int i);
          public static String valueOf(long l);
          public static String valueOf(float f);
          public static String valueOf(double d);
          public String intern();
      }
      public final class StringBuilder implements java.io.Serializable, Comparable<StringBuilder>, CharSequence, Appendable {
          public StringBuilder() {}
          public StringBuilder(int capacity) {}
          public StringBuilder(String str) {}
          public StringBuilder append(Object obj);
          public StringBuilder append(String str);
          public StringBuilder append(CharSequence s);
          public StringBuilder append(char[] str);
          public StringBuilder append(boolean b);
          public StringBuilder append(char c);
          public StringBuilder append(int i);
          public StringBuilder append(long lng);
          public StringBuilder append(float f);
          public StringBuilder append(double d);
          public StringBuilder insert(int offset, String str);
          public StringBuilder delete(int start, int end);
          public StringBuilder deleteCharAt(int index);
          public StringBuilder reverse();
          public void setLength(int newLength);
          public void setCharAt(int index, char ch);
          public int indexOf(String str);
          public int length();
          public char charAt(int index);
          public String substring(int start);
          public String substring(int start, int end);
          public CharSequence subSequence(int start, int end);
          public int compareTo(StringBuilder another);
          public String toString();
      }
      public abstract class Number implements java.io.Serializable {
          public Number() {}
          public abstract int intValue();
          public abstract long longValue();
          public abstract float floatValue();
          public abstract double doubleValue();
          public byte byteValue();
          public short shortValue();
      }
      public final class Integer extends Number implements Comparable<Integer> {
          public static final int MIN_VALUE = 0x80000000;
          public static final int MAX_VALUE = 0x7fffffff;
          public static final Class<Integer> TYPE;
          public Integer(int value) {}
          public static String toString(int i);
          public static String toString(int i, int radix);
          public static String toHexString(int i);
          public static String toBinaryString(int i);
          public static int parseInt(String s) throws NumberFormatException;
          public static int parseInt(String s, int radix) throws NumberFormatException;
          public static Integer valueOf(String s) throws NumberFormatException;
          public static Integer valueOf(int i);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
          public String toString();
          public int hashCode();
          public static int hashCode(int value);
          public boolean equals(Object obj);
          public int compareTo(Integer anotherInteger);
          public static int compare(int x, int y);
          public static int signum(int i);
          public static int sum(int a, int b);
          public static int max(int a, int b);
          public static int min(int a, int b);
          public static int bitCount(int i);
      }
      public final class Long extends Number implements Comparable<Long> {
          public static final long MIN_VALUE = 0x8000000000000000L;
          public static final long MAX_VALUE = 0x7fffffffffffffffL;
          public Long(long value) {}
          public static String toString(long i);
          public static String toString(long i, int radix);
          public static String toHexString(long i);
          public static long parseLong(String s) throws NumberFormatException;
          public static long parseLong(String s, int radix) throws NumberFormatException;
          public static Long valueOf(String s) throws NumberFormatException;
          public static Long valueOf(long l);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
          public String toString();
          public int hashCode();
          public static int hashCode(long value);
          public boolean equals(Object obj);
          public int compareTo(Long anotherLong);
          public static int compare(long x, long y);
          public static long sum(long a, long b);
          public static long max(long a, long b);
          public static long min(long a, long b);
      }
      public final class Short extends Number implements Comparable<Short> {
          public static short parseShort(String s) throws NumberFormatException;
          public static Short valueOf(short s);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
          public int compareTo(Short anotherShort);
      }
      public final class Byte extends Number implements Comparable<Byte> {
          public static byte parseByte(String s) throws NumberFormatException;
          public static Byte valueOf(byte b);
          public static int toUnsignedInt(byte x);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
          public int compareTo(Byte anotherByte);
      }
      public final class Double extends Number implements Comparable<Double> {
          public static final double MAX_VALUE = 0x1.fffffffffffffP+1023;
          public static final double MIN_VALUE = 0x0.0000000000001P-1022;
          public static final double NaN = 0.0d / 0.0;
          public static final double POSITIVE_INFINITY = 1.0 / 0.0;
          public static final double NEGATIVE_INFINITY = -1.0 / 0.0;
          public Double(double value) {}
          public static String toString(double d);
          public static double parseDouble(String s) throws NumberFormatException;
          public static Double valueOf(String s) throws NumberFormatException;
          public static Double valueOf(double d);
          public static boolean isNaN(double v);
          public static boolean isInfinite(double v);
          public static boolean isFinite(double d);
          public boolean isNaN();
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
          public String toString();
          public int compareTo(Double anotherDouble);
          public static int compare(double d1, double d2);
          public static long doubleToLongBits(double value);
          public static double longBitsToDouble(long bits);
      }
      public final class Float extends Number implements Comparable<Float> {
          public static final float MAX_VALUE = 0x1.fffffeP+127f;
          public static float parseFloat(String s) throws NumberFormatException;
          public static Float valueOf(float f);
          public static boolean isNaN(float v);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
          public int compareTo(Float anotherFloat);
          public static int compare(float f1, float f2);
      }
      public final class Boolean implements java.io.Serializable, Comparable<Boolean> {
          public static final Boolean TRUE;
          public static final Boolean FALSE;
          public Boolean(boolean value) {}
          public static boolean parseBoolean(String s);
          public boolean booleanValue();
          public static Boolean valueOf(boolean b);
          public static Boolean valueOf(String s);
          public static String toString(boolean b);
          public String toString();
          public int compareTo(Boolean b);
          public boolean equals(Object obj);
          public int hashCode();
          public static int compare(boolean x, boolean y);
      }
      public final class Character implements java.io.Serializable, Comparable<Character> {
          public Character(char value) {}
          public static Character valueOf(char c);
          public char charValue();
          public static boolean isLetter(char ch);
          public static boolean isDigit(char ch);
          public static boolean isLetterOrDigit(char ch);
          public static boolean isWhitespace(char ch);
          public static boolean isUpperCase(char ch);
          public static boolean isLowerCase(char ch);
          public static char toUpperCase(char ch);
          public static char toLowerCase(char ch);
          public static String toString(char c);
          public static int digit(char ch, int radix);
          public int compareTo(Character anotherCharacter);
      }
      public final class Void {}
      public final class Math {
          public static final double E = 2.718281828459045;
          public static final double PI = 3.141592653589793;
          public static int abs(int a);
          public static long abs(long a);
          public static float abs(float a);
          public static double abs(double a);
          public static int max(int a, int b);
          public static long max(long a, long b);
          public static float max(float a, float b);
          public static double max(double a, double b);
          public static int min(int a, int b);
          public static long min(long a, long b);
          public static float min(float a, float b);
          public static double min(double a, double b);
          public static double sqrt(double a);
          public static double pow(double a, double b);
          public static double floor(double a);
          public static double ceil(double a);
          public static long round(double a);
          public static int round(float a);
          public static double random();
          public static double log(double a);
          public static double exp(double a);
          public static double sin(double a);
          public static double cos(double a);
          public static int floorMod(int x, int y);
          public static int floorDiv(int x, int y);
          public static int addExact(int x, int y);
          public static int toIntExact(long value);
      }
      public final class System {
          public static final InputStream in;
          public static final PrintStream out;
          public static final PrintStream err;
          public static native long currentTimeMillis();
          public static native long nanoTime();
          public static native void arraycopy(Object src, int srcPos, Object dest, int destPos, int length);
          public static String getProperty(String key);
          public static String getProperty(String key, String def);
          public static String getenv(String name);
          public static Map<String, String> getenv();
          public static void exit(int status);
          public static void gc();
          public static String lineSeparator();
          public static native int identityHashCode(Object x);
      }
      public class Thread implements Runnable {
          public Thread() {}
          public Thread(Runnable task) {}
          public Thread(Runnable task, String name) {}
          public Thread(String name) {}
          public static native Thread currentThread();
          public static void sleep(long millis) throws InterruptedException;
          public static native void yield();
          public void start();
          public void run();
          public void interrupt();
          public boolean isInterrupted();
          public static boolean interrupted();
          public final boolean isAlive();
          public final void setDaemon(boolean on);
          public final boolean isDaemon();
          public final void setName(String name);
          public final String getName();
          public final void join() throws InterruptedException;
          public final void join(long millis) throws InterruptedException;
          public void setUncaughtExceptionHandler(UncaughtExceptionHandler ueh);
          public ClassLoader getContextClassLoader();
          @FunctionalInterface public interface UncaughtExceptionHandler { void uncaughtException(Thread t, Throwable e); }
      }
      public final class Class<T> implements java.io.Serializable {
          public String getName();
          public String getSimpleName();
          public String getCanonicalName();
          public boolean isInstance(Object obj);
          public boolean isAssignableFrom(Class<?> cls);
          public boolean isInterface();
          public boolean isArray();
          public boolean isEnum();
          public boolean isRecord();
          public T cast(Object obj);
          public Class<? super T> getSuperclass();
          public Class<?>[] getInterfaces();
          public T[] getEnumConstants();
          public ClassLoader getClassLoader();
          public static Class<?> forName(String className) throws ClassNotFoundException;
          public java.lang.reflect.Field getDeclaredField(String name) throws NoSuchFieldException;
          public java.lang.reflect.Method getMethod(String name, Class<?>... parameterTypes) throws NoSuchMethodException;
          public java.lang.reflect.Method getDeclaredMethod(String name, Class<?>... parameterTypes) throws NoSuchMethodException;
          public java.io.InputStream getResourceAsStream(String name);
          public String toString();
      }
      public abstract class ClassLoader {
          public Class<?> loadClass(String name) throws ClassNotFoundException;
          public java.io.InputStream getResourceAsStream(String name);
          public static ClassLoader getSystemClassLoader();
      }
      public abstract class Enum<E extends Enum<E>> implements Comparable<E>, java.io.Serializable {
          protected Enum(String name, int ordinal) {}
          public final String name();
          public final int ordinal();
          public String toString();
          public final int compareTo(E o);
          public final Class<E> getDeclaringClass();
          public static <T extends Enum<T>> T valueOf(Class<T> enumClass, String name);
      }
      public abstract class Record {
          protected Record() {}
          public abstract boolean equals(Object obj);
          public abstract int hashCode();
          public abstract String toString();
      }
      public class Throwable implements java.io.Serializable {
          public Throwable() {}
          public Throwable(String message) {}
          public Throwable(String message, Throwable cause) {}
          public Throwable(Throwable cause) {}
          public String getMessage();
          public String getLocalizedMessage();
          public Throwable getCause();
          public Throwable initCause(Throwable cause);
          public String toString();
          public void printStackTrace();
          public void printStackTrace(PrintStream s);
          public StackTraceElement[] getStackTrace();
          public final void addSuppressed(Throwable exception);
          public final Throwable[] getSuppressed();
      }
      public final class StackTraceElement implements java.io.Serializable {
          public String getClassName();
          public String getMethodName();
          public String getFileName();
          public int getLineNumber();
      }
      public class Exception extends Throwable {
          public Exception() {}
          public Exception(String message) {}
          public Exception(String message, Throwable cause) {}
          public Exception(Throwable cause) {}
      }
      public class Error extends Throwable {
          public Error() {}
          public Error(String message) {}
          public Error(String message, Throwable cause) {}
          public Error(Throwable cause) {}
      }
      public class AssertionError extends Error {
          public AssertionError() {}
          public AssertionError(Object detailMessage) {}
          public AssertionError(String message, Throwable cause) {}
      }
      public class OutOfMemoryError extends Error { public OutOfMemoryError() {} public OutOfMemoryError(String s) {} }
      public class StackOverflowError extends Error { public StackOverflowError() {} public StackOverflowError(String s) {} }
      public class RuntimeException extends Exception {
          public RuntimeException() {}
          public RuntimeException(String message) {}
          public RuntimeException(String message, Throwable cause) {}
          public RuntimeException(Throwable cause) {}
      }
      public class IllegalArgumentException extends RuntimeException {
          public IllegalArgumentException() {}
          public IllegalArgumentException(String s) {}
          public IllegalArgumentException(String message, Throwable cause) {}
          public IllegalArgumentException(Throwable cause) {}
      }
      public class IllegalStateException extends RuntimeException {
          public IllegalStateException() {}
          public IllegalStateException(String s) {}
          public IllegalStateException(String message, Throwable cause) {}
          public IllegalStateException(Throwable cause) {}
      }
      public class NumberFormatException extends IllegalArgumentException { public NumberFormatException() {} public NumberFormatException(String s) {} }
      public class NullPointerException extends RuntimeException { public NullPointerException() {} public NullPointerException(String s) {} }
      public class ClassCastException extends RuntimeException { public ClassCastException() {} public ClassCastException(String s) {} }
      public class ArithmeticException extends RuntimeException { public ArithmeticException() {} public ArithmeticException(String s) {} }
      public class IndexOutOfBoundsException extends RuntimeException {
          public IndexOutOfBoundsException() {}
          public IndexOutOfBoundsException(String s) {}
          public IndexOutOfBoundsException(int index) {}
      }
      public class ArrayIndexOutOfBoundsException extends IndexOutOfBoundsException { public ArrayIndexOutOfBoundsException() {} public ArrayIndexOutOfBoundsException(String s) {} }
      public class StringIndexOutOfBoundsException extends IndexOutOfBoundsException { public StringIndexOutOfBoundsException() {} public StringIndexOutOfBoundsException(String s) {} }
      public class ArrayStoreException extends RuntimeException { public ArrayStoreException() {} public ArrayStoreException(String s) {} }
      public class NegativeArraySizeException extends RuntimeException { public NegativeArraySizeException() {} public NegativeArraySizeException(String s) {} }
      public class UnsupportedOperationException extends RuntimeException {
          public UnsupportedOperationException() {}
          public UnsupportedOperationException(String message) {}
          public UnsupportedOperationException(String message, Throwable cause) {}
      }
      public class SecurityException extends RuntimeException { public SecurityException() {} public SecurityException(String s) {} }
      public class InterruptedException extends Exception { public InterruptedException() {} public InterruptedException(String s) {} }
      public class CloneNotSupportedException extends Exception { public CloneNotSupportedException() {} public CloneNotSupportedException(String s) {} }
      public class ReflectiveOperationException extends Exception {
          public ReflectiveOperationException() {}
          public ReflectiveOperationException(String message) {}
          public ReflectiveOperationException(String message, Throwable cause) {}
      }
      public class ClassNotFoundException extends ReflectiveOperationException { public ClassNotFoundException() {} public ClassNotFoundException(String s) {} }
      public class NoSuchFieldException extends ReflectiveOperationException { public NoSuchFieldException() {} public NoSuchFieldException(String s) {} }
      public class NoSuchMethodException extends ReflectiveOperationException { public NoSuchMethodException() {} public NoSuchMethodException(String s) {} }
      public interface Cloneable {}
      public final class ThreadLocal<T> {
          public ThreadLocal() {}
          public static <S> ThreadLocal<S> withInitial(Supplier<? extends S> supplier);
          public T get();
          public void set(T value);
          public void remove();
      }
      public class Runtime {
          public static Runtime getRuntime();
          public int availableProcessors();
          public long freeMemory();
          public long totalMemory();
          public long maxMemory();
          public void addShutdownHook(Thread hook);
          public Process exec(String command) throws IOException;
      }
      public abstract class Process {
          public abstract OutputStream getOutputStream();
          public abstract InputStream getInputStream();
          public abstract InputStream getErrorStream();
          public abstract int waitFor() throws InterruptedException;
          public boolean waitFor(long timeout, java.util.concurrent.TimeUnit unit) throws InterruptedException;
          public Process destroyForcibly();
          public abstract int exitValue();
          public abstract void destroy();
          public boolean isAlive();
          public long pid();
      }
      public final class ProcessBuilder {
          public ProcessBuilder(List<String> command) {}
          public ProcessBuilder(String... command) {}
          public ProcessBuilder command(List<String> command);
          public List<String> command();
          public Map<String, String> environment();
          public ProcessBuilder directory(File directory);
          public ProcessBuilder redirectErrorStream(boolean redirectErrorStream);
          public ProcessBuilder inheritIO();
          public Process start() throws IOException;
      }
      @Retention(RetentionPolicy.SOURCE) public @interface Override {}
      @Retention(RetentionPolicy.RUNTIME) public @interface Deprecated { String since() default ""; boolean forRemoval() default false; }
      @Retention(RetentionPolicy.SOURCE) public @interface SuppressWarnings { String[] value(); }
      @Retention(RetentionPolicy.RUNTIME) public @interface FunctionalInterface {}
      @Retention(RetentionPolicy.RUNTIME) public @interface SafeVarargs {}
      """,
    "java/lang/annotation/annotation.java": """
      package java.lang.annotation;
      public interface Annotation { Class<? extends Annotation> annotationType(); }
      public enum RetentionPolicy { SOURCE, CLASS, RUNTIME }
      public enum ElementType { TYPE, FIELD, METHOD, PARAMETER, CONSTRUCTOR, LOCAL_VARIABLE, ANNOTATION_TYPE, PACKAGE, TYPE_PARAMETER, TYPE_USE, MODULE, RECORD_COMPONENT }
      public @interface Retention { RetentionPolicy value(); }
      public @interface Target { ElementType[] value(); }
      public @interface Documented {}
      public @interface Inherited {}
      """,
    "java/lang/reflect/reflect.java": """
      package java.lang.reflect;
      public class AccessibleObject {
          public void setAccessible(boolean flag);
          public boolean isAnnotationPresent(Class<? extends java.lang.annotation.Annotation> annotationClass);
          public <T extends java.lang.annotation.Annotation> T getAnnotation(Class<T> annotationClass);
      }
      public final class Field extends AccessibleObject {
          public String getName();
          public Class<?> getType();
          public int getModifiers();
          public Object get(Object obj) throws IllegalAccessException;
          public void set(Object obj, Object value) throws IllegalAccessException;
      }
      public final class Method extends AccessibleObject {
          public String getName();
          public Class<?> getReturnType();
          public Class<?>[] getParameterTypes();
          public int getModifiers();
          public Object invoke(Object obj, Object... args) throws IllegalAccessException, InvocationTargetException;
      }
      public class InvocationTargetException extends ReflectiveOperationException { public Throwable getTargetException(); }
      """,
    "java/util/function/function.java": """
      package java.util.function;
      @FunctionalInterface public interface Function<T, R> {
          R apply(T t);
          default <V> Function<V, R> compose(Function<? super V, ? extends T> before);
          default <V> Function<T, V> andThen(Function<? super R, ? extends V> after);
          static <T> Function<T, T> identity();
      }
      @FunctionalInterface public interface BiFunction<T, U, R> {
          R apply(T t, U u);
          default <V> BiFunction<T, U, V> andThen(Function<? super R, ? extends V> after);
      }
      @FunctionalInterface public interface UnaryOperator<T> extends Function<T, T> { static <T> UnaryOperator<T> identity(); }
      @FunctionalInterface public interface BinaryOperator<T> extends BiFunction<T, T, T> {}
      @FunctionalInterface public interface Consumer<T> {
          void accept(T t);
          default Consumer<T> andThen(Consumer<? super T> after);
      }
      @FunctionalInterface public interface BiConsumer<T, U> { void accept(T t, U u); }
      @FunctionalInterface public interface Supplier<T> { T get(); }
      @FunctionalInterface public interface Predicate<T> {
          boolean test(T t);
          default Predicate<T> and(Predicate<? super T> other);
          default Predicate<T> negate();
          default Predicate<T> or(Predicate<? super T> other);
          static <T> Predicate<T> isEqual(Object targetRef);
          static <T> Predicate<T> not(Predicate<? super T> target);
      }
      @FunctionalInterface public interface BiPredicate<T, U> { boolean test(T t, U u); }
      @FunctionalInterface public interface IntFunction<R> { R apply(int value); }
      @FunctionalInterface public interface ToIntFunction<T> { int applyAsInt(T value); }
      @FunctionalInterface public interface ToLongFunction<T> { long applyAsLong(T value); }
      @FunctionalInterface public interface ToDoubleFunction<T> { double applyAsDouble(T value); }
      @FunctionalInterface public interface IntPredicate { boolean test(int value); }
      @FunctionalInterface public interface IntConsumer { void accept(int value); }
      @FunctionalInterface public interface IntUnaryOperator { int applyAsInt(int operand); }
      @FunctionalInterface public interface IntBinaryOperator { int applyAsInt(int left, int right); }
      @FunctionalInterface public interface IntSupplier { int getAsInt(); }
      @FunctionalInterface public interface LongSupplier { long getAsLong(); }
      @FunctionalInterface public interface BooleanSupplier { boolean getAsBoolean(); }
      @FunctionalInterface public interface DoubleSupplier { double getAsDouble(); }
      """,
    "java/util/util.java": """
      package java.util;
      import java.util.function.*;
      import java.util.stream.*;
      public interface Iterator<E> {
          boolean hasNext();
          E next();
          default void remove();
          default void forEachRemaining(Consumer<? super E> action);
      }
      public interface ListIterator<E> extends Iterator<E> {
          boolean hasPrevious();
          E previous();
          int nextIndex();
          void set(E e);
          void add(E e);
      }
      @FunctionalInterface public interface Comparator<T> {
          int compare(T o1, T o2);
          default Comparator<T> reversed();
          default Comparator<T> thenComparing(Comparator<? super T> other);
          default <U extends Comparable<? super U>> Comparator<T> thenComparing(Function<? super T, ? extends U> keyExtractor);
          default Comparator<T> thenComparingInt(ToIntFunction<? super T> keyExtractor);
          static <T extends Comparable<? super T>> Comparator<T> naturalOrder();
          static <T extends Comparable<? super T>> Comparator<T> reverseOrder();
          static <T, U extends Comparable<? super U>> Comparator<T> comparing(Function<? super T, ? extends U> keyExtractor);
          static <T> Comparator<T> comparingInt(ToIntFunction<? super T> keyExtractor);
          static <T> Comparator<T> comparingLong(ToLongFunction<? super T> keyExtractor);
          static <T> Comparator<T> comparingDouble(ToDoubleFunction<? super T> keyExtractor);
      }
      public interface Collection<E> extends Iterable<E> {
          int size();
          boolean isEmpty();
          boolean contains(Object o);
          Iterator<E> iterator();
          Object[] toArray();
          <T> T[] toArray(T[] a);
          boolean add(E e);
          boolean remove(Object o);
          boolean containsAll(Collection<?> c);
          boolean addAll(Collection<? extends E> c);
          boolean removeAll(Collection<?> c);
          default boolean removeIf(Predicate<? super E> filter);
          boolean retainAll(Collection<?> c);
          void clear();
          default Stream<E> stream();
          default Stream<E> parallelStream();
      }
      public interface SequencedCollection<E> extends Collection<E> {
          default E getFirst();
          default E getLast();
          default E removeFirst();
          default E removeLast();
          default void addFirst(E e);
          default void addLast(E e);
      }
      public interface List<E> extends SequencedCollection<E> {
          E get(int index);
          E set(int index, E element);
          void add(int index, E element);
          E remove(int index);
          int indexOf(Object o);
          int lastIndexOf(Object o);
          boolean addAll(int index, Collection<? extends E> c);
          ListIterator<E> listIterator();
          List<E> subList(int fromIndex, int toIndex);
          default void sort(Comparator<? super E> c);
          default void replaceAll(UnaryOperator<E> operator);
          static <E> List<E> of();
          static <E> List<E> of(E e1);
          static <E> List<E> of(E e1, E e2);
          static <E> List<E> of(E e1, E e2, E e3);
          static <E> List<E> of(E... elements);
          static <E> List<E> copyOf(Collection<? extends E> coll);
      }
      public interface Set<E> extends Collection<E> {
          static <E> Set<E> of();
          static <E> Set<E> of(E e1);
          static <E> Set<E> of(E e1, E e2);
          static <E> Set<E> of(E... elements);
          static <E> Set<E> copyOf(Collection<? extends E> coll);
      }
      public interface SortedSet<E> extends Set<E> { E first(); E last(); }
      public interface NavigableSet<E> extends SortedSet<E> {}
      public interface Queue<E> extends Collection<E> {
          boolean offer(E e);
          E poll();
          E peek();
          E remove();
          E element();
      }
      public interface Deque<E> extends Queue<E> {
          void addFirst(E e);
          void addLast(E e);
          E pollFirst();
          E pollLast();
          E peekFirst();
          E peekLast();
          void push(E e);
          E pop();
      }
      public interface Map<K, V> {
          int size();
          boolean isEmpty();
          boolean containsKey(Object key);
          boolean containsValue(Object value);
          V get(Object key);
          V put(K key, V value);
          V remove(Object key);
          void putAll(Map<? extends K, ? extends V> m);
          void clear();
          Set<K> keySet();
          Collection<V> values();
          Set<Map.Entry<K, V>> entrySet();
          default V getOrDefault(Object key, V defaultValue);
          default void forEach(BiConsumer<? super K, ? super V> action);
          default V putIfAbsent(K key, V value);
          default V computeIfAbsent(K key, Function<? super K, ? extends V> mappingFunction);
          default V computeIfPresent(K key, BiFunction<? super K, ? super V, ? extends V> remappingFunction);
          default V compute(K key, BiFunction<? super K, ? super V, ? extends V> remappingFunction);
          default V merge(K key, V value, BiFunction<? super V, ? super V, ? extends V> remappingFunction);
          default V replace(K key, V value);
          static <K, V> Map<K, V> of();
          static <K, V> Map<K, V> of(K k1, V v1);
          static <K, V> Map<K, V> of(K k1, V v1, K k2, V v2);
          static <K, V> Map<K, V> of(K k1, V v1, K k2, V v2, K k3, V v3);
          static <K, V> Map<K, V> of(K k1, V v1, K k2, V v2, K k3, V v3, K k4, V v4);
          static <K, V> Map<K, V> copyOf(Map<? extends K, ? extends V> map);
          static <K, V> Map.Entry<K, V> entry(K k, V v);
          interface Entry<K, V> {
              K getKey();
              V getValue();
              V setValue(V value);
          }
      }
      public interface SortedMap<K, V> extends Map<K, V> { K firstKey(); K lastKey(); }
      public interface NavigableMap<K, V> extends SortedMap<K, V> {}
      public abstract class AbstractCollection<E> implements Collection<E> { protected AbstractCollection() {} }
      public abstract class AbstractList<E> extends AbstractCollection<E> implements List<E> { protected AbstractList() {} }
      public abstract class AbstractMap<K, V> implements Map<K, V> { protected AbstractMap() {} }
      public class ArrayList<E> extends AbstractList<E> implements List<E>, RandomAccess, Cloneable, java.io.Serializable {
          public ArrayList() {}
          public ArrayList(int initialCapacity) {}
          public ArrayList(Collection<? extends E> c) {}
          public int size();
          public boolean isEmpty();
          public boolean contains(Object o);
          public Iterator<E> iterator();
          public boolean add(E e);
          public boolean remove(Object o);
          public void clear();
          public E get(int index);
          public E set(int index, E element);
          public void add(int index, E element);
          public E remove(int index);
          public int indexOf(Object o);
          public boolean addAll(Collection<? extends E> c);
          public boolean removeIf(Predicate<? super E> filter);
          public void forEach(Consumer<? super E> action);
          public void sort(Comparator<? super E> c);
          public List<E> subList(int fromIndex, int toIndex);
          public Object[] toArray();
          public <T> T[] toArray(T[] a);
          public void ensureCapacity(int minCapacity);
          public void trimToSize();
      }
      public class LinkedList<E> extends AbstractList<E> implements List<E>, Deque<E>, Cloneable, java.io.Serializable {
          public LinkedList() {}
          public LinkedList(Collection<? extends E> c) {}
          public int size();
          public boolean isEmpty();
          public boolean contains(Object o);
          public Iterator<E> iterator();
          public boolean add(E e);
          public boolean remove(Object o);
          public void clear();
          public E get(int index);
          public void addFirst(E e);
          public void addLast(E e);
          public E poll();
          public E peek();
          public E pollFirst();
          public E pollLast();
          public E peekFirst();
          public E peekLast();
          public E removeFirst();
          public E removeLast();
          public boolean offer(E e);
          public void push(E e);
          public E pop();
      }
      public class ArrayDeque<E> extends AbstractCollection<E> implements Deque<E>, Cloneable, java.io.Serializable {
          public ArrayDeque() {}
          public ArrayDeque(int numElements) {}
          public ArrayDeque(Collection<? extends E> c) {}
          public int size();
          public boolean isEmpty();
          public boolean contains(Object o);
          public Iterator<E> iterator();
          public boolean add(E e);
          public boolean remove(Object o);
          public void clear();
          public void addFirst(E e);
          public void addLast(E e);
          public boolean offer(E e);
          public E poll();
          public E peek();
          public E pollFirst();
          public E pollLast();
          public E peekFirst();
          public E peekLast();
          public E removeFirst();
          public E removeLast();
          public void push(E e);
          public E pop();
      }
      public class PriorityQueue<E> extends AbstractCollection<E> implements Queue<E>, java.io.Serializable {
          public PriorityQueue() {}
          public PriorityQueue(Comparator<? super E> comparator) {}
      }
      public interface RandomAccess {}
      public class HashMap<K, V> extends AbstractMap<K, V> implements Map<K, V>, Cloneable, java.io.Serializable {
          public HashMap() {}
          public HashMap(int initialCapacity) {}
          public HashMap(Map<? extends K, ? extends V> m) {}
          public int size();
          public boolean isEmpty();
          public V get(Object key);
          public boolean containsKey(Object key);
          public V put(K key, V value);
          public V remove(Object key);
          public void clear();
          public boolean containsValue(Object value);
          public Set<K> keySet();
          public Collection<V> values();
          public Set<Map.Entry<K, V>> entrySet();
          public V getOrDefault(Object key, V defaultValue);
          public V putIfAbsent(K key, V value);
          public V computeIfAbsent(K key, Function<? super K, ? extends V> mappingFunction);
          public V merge(K key, V value, BiFunction<? super V, ? super V, ? extends V> remappingFunction);
          public void forEach(BiConsumer<? super K, ? super V> action);
      }
      public class LinkedHashMap<K, V> extends HashMap<K, V> implements Map<K, V> {
          public LinkedHashMap() {}
          public LinkedHashMap(int initialCapacity) {}
          public LinkedHashMap(Map<? extends K, ? extends V> m) {}
          public LinkedHashMap(int initialCapacity, float loadFactor, boolean accessOrder) {}
          protected boolean removeEldestEntry(Map.Entry<K, V> eldest);
          public V get(Object key);
          public V getOrDefault(Object key, V defaultValue);
          public void clear();
          public boolean containsValue(Object value);
          public Set<K> keySet();
          public Collection<V> values();
          public Set<Map.Entry<K, V>> entrySet();
          public void forEach(BiConsumer<? super K, ? super V> action);
      }
      public class TreeMap<K, V> extends AbstractMap<K, V> implements NavigableMap<K, V>, Cloneable, java.io.Serializable {
          public TreeMap() {}
          public TreeMap(Comparator<? super K> comparator) {}
          public TreeMap(Map<? extends K, ? extends V> m) {}
          public int size();
          public boolean isEmpty();
          public V get(Object key);
          public boolean containsKey(Object key);
          public V put(K key, V value);
          public V remove(Object key);
          public void clear();
          public boolean containsValue(Object value);
          public Set<K> keySet();
          public Collection<V> values();
          public Set<Map.Entry<K, V>> entrySet();
          public V getOrDefault(Object key, V defaultValue);
          public V putIfAbsent(K key, V value);
          public V computeIfAbsent(K key, Function<? super K, ? extends V> mappingFunction);
          public V merge(K key, V value, BiFunction<? super V, ? super V, ? extends V> remappingFunction);
          public void forEach(BiConsumer<? super K, ? super V> action);
      }
      public class IdentityHashMap<K, V> extends AbstractMap<K, V> implements Map<K, V>, java.io.Serializable, Cloneable { public IdentityHashMap() {} }
      public class WeakHashMap<K, V> extends AbstractMap<K, V> implements Map<K, V> { public WeakHashMap() {} }
      public abstract class AbstractSet<E> extends AbstractCollection<E> implements Set<E> { protected AbstractSet() {} }
      public class HashSet<E> extends AbstractSet<E> implements Set<E>, Cloneable, java.io.Serializable {
          public HashSet() {}
          public HashSet(Collection<? extends E> c) {}
          public HashSet(int initialCapacity) {}
          public int size();
          public boolean isEmpty();
          public boolean contains(Object o);
          public Iterator<E> iterator();
          public boolean add(E e);
          public boolean remove(Object o);
          public void clear();
      }
      public class LinkedHashSet<E> extends HashSet<E> implements Set<E>, Cloneable, java.io.Serializable {
          public LinkedHashSet() {}
          public LinkedHashSet(Collection<? extends E> c) {}
          public LinkedHashSet(int initialCapacity) {}
      }
      public class TreeSet<E> extends AbstractSet<E> implements NavigableSet<E>, Cloneable, java.io.Serializable {
          public TreeSet() {}
          public TreeSet(Comparator<? super E> comparator) {}
          public TreeSet(Collection<? extends E> c) {}
      }
      public class EnumMap<K extends Enum<K>, V> extends AbstractMap<K, V> implements java.io.Serializable, Cloneable { public EnumMap(Class<K> keyType) {} }
      public abstract class EnumSet<E extends Enum<E>> extends AbstractSet<E> implements Cloneable, java.io.Serializable {
          public static <E extends Enum<E>> EnumSet<E> noneOf(Class<E> elementType);
          public static <E extends Enum<E>> EnumSet<E> allOf(Class<E> elementType);
          public static <E extends Enum<E>> EnumSet<E> of(E e);
          public static <E extends Enum<E>> EnumSet<E> of(E first, E... rest);
      }
      public final class Optional<T> {
          public static <T> Optional<T> empty();
          public static <T> Optional<T> of(T value);
          public static <T> Optional<T> ofNullable(T value);
          public T get();
          public boolean isPresent();
          public boolean isEmpty();
          public void ifPresent(Consumer<? super T> action);
          public void ifPresentOrElse(Consumer<? super T> action, Runnable emptyAction);
          public Optional<T> filter(Predicate<? super T> predicate);
          public <U> Optional<U> map(Function<? super T, ? extends U> mapper);
          public <U> Optional<U> flatMap(Function<? super T, ? extends Optional<? extends U>> mapper);
          public Optional<T> or(Supplier<? extends Optional<? extends T>> supplier);
          public Stream<T> stream();
          public T orElse(T other);
          public T orElseGet(Supplier<? extends T> supplier);
          public T orElseThrow();
          public <X extends Throwable> T orElseThrow(Supplier<? extends X> exceptionSupplier) throws X;
      }
      public final class Objects {
          public static boolean equals(Object a, Object b);
          public static int hashCode(Object o);
          public static int hash(Object... values);
          public static String toString(Object o);
          public static String toString(Object o, String nullDefault);
          public static boolean isNull(Object obj);
          public static boolean nonNull(Object obj);
          public static <T> T requireNonNull(T obj);
          public static <T> T requireNonNull(T obj, String message);
          public static <T> T requireNonNullElse(T obj, T defaultObj);
      }
      public final class Arrays {
          public static <T> List<T> asList(T... a);
          public static void sort(int[] a);
          public static void sort(long[] a);
          public static void sort(Object[] a);
          public static <T> void sort(T[] a, Comparator<? super T> c);
          public static String toString(int[] a);
          public static String toString(long[] a);
          public static String toString(byte[] a);
          public static String toString(Object[] a);
          public static boolean equals(byte[] a, byte[] a2);
          public static boolean equals(int[] a, int[] a2);
          public static boolean equals(Object[] a, Object[] a2);
          public static int hashCode(byte[] a);
          public static int hashCode(Object[] a);
          public static void fill(int[] a, int val);
          public static void fill(byte[] a, byte val);
          public static void fill(char[] a, char val);
          public static void fill(Object[] a, Object val);
          public static byte[] copyOf(byte[] original, int newLength);
          public static int[] copyOf(int[] original, int newLength);
          public static char[] copyOf(char[] original, int newLength);
          public static <T> T[] copyOf(T[] original, int newLength);
          public static byte[] copyOfRange(byte[] original, int from, int to);
          public static <T> T[] copyOfRange(T[] original, int from, int to);
          public static <T> Stream<T> stream(T[] array);
          public static IntStream stream(int[] array);
      }
      public class Collections {
          public static <T extends Comparable<? super T>> void sort(List<T> list);
          public static <T> void sort(List<T> list, Comparator<? super T> c);
          public static void reverse(List<?> list);
          public static void shuffle(List<?> list);
          public static <T> List<T> emptyList();
          public static <T> Set<T> emptySet();
          public static <K, V> Map<K, V> emptyMap();
          public static <T> List<T> singletonList(T o);
          public static <T> Set<T> singleton(T o);
          public static <K, V> Map<K, V> singletonMap(K key, V value);
          public static <T> List<T> unmodifiableList(List<? extends T> list);
          public static <T> Set<T> unmodifiableSet(Set<? extends T> s);
          public static <K, V> Map<K, V> unmodifiableMap(Map<? extends K, ? extends V> m);
          public static <T> Collection<T> unmodifiableCollection(Collection<? extends T> c);
          public static <T> List<T> synchronizedList(List<T> list);
          public static <K, V> Map<K, V> synchronizedMap(Map<K, V> m);
          public static <T> boolean addAll(Collection<? super T> c, T... elements);
          public static <T extends Object & Comparable<? super T>> T max(Collection<? extends T> coll);
          public static <T extends Object & Comparable<? super T>> T min(Collection<? extends T> coll);
          public static <T> List<T> nCopies(int n, T o);
      }
      public class Random implements java.io.Serializable {
          public Random() {}
          public Random(long seed) {}
          public int nextInt();
          public int nextInt(int bound);
          public long nextLong();
          public double nextDouble();
          public boolean nextBoolean();
          public void nextBytes(byte[] bytes);
      }
      public final class UUID implements java.io.Serializable, Comparable<UUID> {
          public UUID(long mostSigBits, long leastSigBits) {}
          public static UUID randomUUID();
          public static UUID fromString(String name);
          public String toString();
          public int compareTo(UUID val);
      }
      public final class StringJoiner {
          public StringJoiner(CharSequence delimiter) {}
          public StringJoiner(CharSequence delimiter, CharSequence prefix, CharSequence suffix) {}
          public StringJoiner add(CharSequence newElement);
          public String toString();
      }
      public final class Scanner implements Iterator<String>, java.io.Closeable {
          public Scanner(java.io.InputStream source) {}
          public Scanner(String source) {}
          public boolean hasNext();
          public String next();
          public boolean hasNextLine();
          public String nextLine();
          public int nextInt();
          public void close();
      }
      public class Base64 {
          public static Encoder getEncoder();
          public static Decoder getDecoder();
          public static Encoder getUrlEncoder();
          public static Decoder getUrlDecoder();
          public static class Encoder {
              public byte[] encode(byte[] src);
              public String encodeToString(byte[] src);
              public Encoder withoutPadding();
          }
          public static class Decoder {
              public byte[] decode(byte[] src);
              public byte[] decode(String src);
          }
      }
      public class NoSuchElementException extends RuntimeException { public NoSuchElementException() {} public NoSuchElementException(String s) {} }
      public class ConcurrentModificationException extends RuntimeException { public ConcurrentModificationException() {} public ConcurrentModificationException(String message) {} }
      public class EventObject implements java.io.Serializable { public EventObject(Object source) {} public Object getSource(); }
      public interface EventListener {}
      public final class Locale implements Cloneable, java.io.Serializable {
          public static final Locale ROOT;
          public static final Locale US;
          public static final Locale ENGLISH;
          public static Locale getDefault();
      }
      """,
    "java/util/stream/stream.java": """
      package java.util.stream;
      import java.util.*;
      import java.util.function.*;
      public interface BaseStream<T, S extends BaseStream<T, S>> extends AutoCloseable {
          Iterator<T> iterator();
          S parallel();
          S sequential();
          void close();
      }
      public interface Stream<T> extends BaseStream<T, Stream<T>> {
          Stream<T> filter(Predicate<? super T> predicate);
          <R> Stream<R> map(Function<? super T, ? extends R> mapper);
          IntStream mapToInt(ToIntFunction<? super T> mapper);
          LongStream mapToLong(ToLongFunction<? super T> mapper);
          <R> Stream<R> flatMap(Function<? super T, ? extends Stream<? extends R>> mapper);
          Stream<T> distinct();
          Stream<T> sorted();
          Stream<T> sorted(Comparator<? super T> comparator);
          Stream<T> peek(Consumer<? super T> action);
          Stream<T> limit(long maxSize);
          Stream<T> skip(long n);
          void forEach(Consumer<? super T> action);
          Object[] toArray();
          <A> A[] toArray(IntFunction<A[]> generator);
          T reduce(T identity, BinaryOperator<T> accumulator);
          Optional<T> reduce(BinaryOperator<T> accumulator);
          <R, A> R collect(Collector<? super T, A, R> collector);
          default List<T> toList();
          Optional<T> min(Comparator<? super T> comparator);
          Optional<T> max(Comparator<? super T> comparator);
          long count();
          boolean anyMatch(Predicate<? super T> predicate);
          boolean allMatch(Predicate<? super T> predicate);
          boolean noneMatch(Predicate<? super T> predicate);
          Optional<T> findFirst();
          Optional<T> findAny();
          static <T> Stream<T> empty();
          static <T> Stream<T> of(T t);
          static <T> Stream<T> of(T... values);
          static <T> Stream<T> iterate(T seed, UnaryOperator<T> f);
          static <T> Stream<T> generate(Supplier<? extends T> s);
          static <T> Stream<T> concat(Stream<? extends T> a, Stream<? extends T> b);
      }
      public interface IntStream extends BaseStream<Integer, IntStream> {
          IntStream filter(IntPredicate predicate);
          IntStream map(IntUnaryOperator mapper);
          <U> Stream<U> mapToObj(IntFunction<? extends U> mapper);
          Stream<Integer> boxed();
          void forEach(IntConsumer action);
          int sum();
          OptionalInt min();
          OptionalInt max();
          long count();
          int[] toArray();
          static IntStream range(int startInclusive, int endExclusive);
          static IntStream rangeClosed(int startInclusive, int endInclusive);
          static IntStream of(int... values);
      }
      public interface LongStream extends BaseStream<Long, LongStream> { long sum(); long count(); }
      public interface Collector<T, A, R> {}
      public final class Collectors {
          public static <T> Collector<T, ?, List<T>> toList();
          public static <T> Collector<T, ?, Set<T>> toSet();
          public static Collector<CharSequence, ?, String> joining();
          public static Collector<CharSequence, ?, String> joining(CharSequence delimiter);
          public static Collector<CharSequence, ?, String> joining(CharSequence delimiter, CharSequence prefix, CharSequence suffix);
          public static <T, K, U> Collector<T, ?, Map<K, U>> toMap(Function<? super T, ? extends K> keyMapper, Function<? super T, ? extends U> valueMapper);
          public static <T, K> Collector<T, ?, Map<K, List<T>>> groupingBy(Function<? super T, ? extends K> classifier);
          public static <T> Collector<T, ?, Long> counting();
      }
      """,
    "java/util/OptionalInt.java": """
      package java.util;
      public final class OptionalInt {
          public static OptionalInt empty();
          public static OptionalInt of(int value);
          public int getAsInt();
          public boolean isPresent();
          public int orElse(int other);
      }
      """,
    "java/util/concurrent/concurrent.java": """
      package java.util.concurrent;
      import java.util.*;
      import java.util.function.*;
      public enum TimeUnit {
          NANOSECONDS, MICROSECONDS, MILLISECONDS, SECONDS, MINUTES, HOURS, DAYS;
          public long toMillis(long duration);
          public long toNanos(long duration);
          public long toSeconds(long duration);
          public void sleep(long timeout) throws InterruptedException;
      }
      public interface Future<V> {
          boolean cancel(boolean mayInterruptIfRunning);
          boolean isCancelled();
          boolean isDone();
          V get() throws InterruptedException, ExecutionException;
          V get(long timeout, TimeUnit unit) throws InterruptedException, ExecutionException, TimeoutException;
      }
      public interface CompletionStage<T> {
          <U> CompletionStage<U> thenApply(Function<? super T, ? extends U> fn);
          CompletionStage<Void> thenAccept(Consumer<? super T> action);
          CompletableFuture<T> toCompletableFuture();
      }
      public class CompletableFuture<T> implements Future<T>, CompletionStage<T> {
          public CompletableFuture() {}
          public static <U> CompletableFuture<U> supplyAsync(Supplier<U> supplier);
          public static <U> CompletableFuture<U> supplyAsync(Supplier<U> supplier, Executor executor);
          public static CompletableFuture<Void> runAsync(Runnable runnable);
          public static CompletableFuture<Void> runAsync(Runnable runnable, Executor executor);
          public static <U> CompletableFuture<U> completedFuture(U value);
          public static <U> CompletableFuture<U> failedFuture(Throwable ex);
          public static CompletableFuture<Void> allOf(CompletableFuture<?>... cfs);
          public boolean complete(T value);
          public boolean completeExceptionally(Throwable ex);
          public T join();
          public T get() throws InterruptedException, ExecutionException;
          public T get(long timeout, TimeUnit unit) throws InterruptedException, ExecutionException, TimeoutException;
          public T getNow(T valueIfAbsent);
          public boolean isDone();
          public boolean cancel(boolean mayInterruptIfRunning);
          public boolean isCancelled();
          public <U> CompletableFuture<U> thenApply(Function<? super T, ? extends U> fn);
          public CompletableFuture<Void> thenAccept(Consumer<? super T> action);
          public CompletableFuture<Void> thenRun(Runnable action);
          public <U> CompletableFuture<U> thenCompose(Function<? super T, ? extends CompletionStage<U>> fn);
          public CompletableFuture<T> whenComplete(BiConsumer<? super T, ? super Throwable> action);
          public CompletableFuture<T> exceptionally(Function<Throwable, ? extends T> fn);
          public CompletableFuture<T> orTimeout(long timeout, TimeUnit unit);
          public CompletableFuture<T> toCompletableFuture();
      }
      public interface Executor { void execute(Runnable command); }
      public interface ExecutorService extends Executor, AutoCloseable {
          void shutdown();
          List<Runnable> shutdownNow();
          boolean isShutdown();
          boolean awaitTermination(long timeout, TimeUnit unit) throws InterruptedException;
          <T> Future<T> submit(Callable<T> task);
          Future<?> submit(Runnable task);
          default void close();
      }
      public interface ScheduledExecutorService extends ExecutorService {
          ScheduledFuture<?> schedule(Runnable command, long delay, TimeUnit unit);
          ScheduledFuture<?> scheduleAtFixedRate(Runnable command, long initialDelay, long period, TimeUnit unit);
      }
      public interface ScheduledFuture<V> extends Future<V> {}
      @FunctionalInterface public interface Callable<V> { V call() throws Exception; }
      public class Executors {
          public static ExecutorService newFixedThreadPool(int nThreads);
          public static ExecutorService newCachedThreadPool();
          public static ExecutorService newSingleThreadExecutor();
          public static ExecutorService newVirtualThreadPerTaskExecutor();
          public static ScheduledExecutorService newScheduledThreadPool(int corePoolSize);
          public static ScheduledExecutorService newSingleThreadScheduledExecutor();
      }
      public class ConcurrentHashMap<K, V> extends AbstractMap<K, V> implements ConcurrentMap<K, V>, java.io.Serializable {
          public ConcurrentHashMap() {}
          public ConcurrentHashMap(int initialCapacity) {}
          public int size();
          public boolean isEmpty();
          public V get(Object key);
          public boolean containsKey(Object key);
          public V put(K key, V value);
          public V remove(Object key);
          public void clear();
          public boolean containsValue(Object value);
          public Set<K> keySet();
          public Collection<V> values();
          public Set<Map.Entry<K, V>> entrySet();
          public V getOrDefault(Object key, V defaultValue);
          public V putIfAbsent(K key, V value);
          public V computeIfAbsent(K key, Function<? super K, ? extends V> mappingFunction);
          public V merge(K key, V value, BiFunction<? super V, ? super V, ? extends V> remappingFunction);
          public void forEach(BiConsumer<? super K, ? super V> action);
      }
      public interface ConcurrentMap<K, V> extends Map<K, V> {}
      public class ConcurrentLinkedQueue<E> extends AbstractCollection<E> implements Queue<E>, java.io.Serializable {
          public ConcurrentLinkedQueue() {}
          public boolean add(E e);
          public boolean offer(E e);
          public E poll();
          public E peek();
          public boolean isEmpty();
          public int size();
          public boolean contains(Object o);
          public boolean remove(Object o);
          public Iterator<E> iterator();
      }
      public class CopyOnWriteArrayList<E> implements List<E>, RandomAccess, Cloneable, java.io.Serializable { public CopyOnWriteArrayList() {} }
      public interface BlockingQueue<E> extends Queue<E> {
          void put(E e) throws InterruptedException;
          E take() throws InterruptedException;
          boolean offer(E e, long timeout, TimeUnit unit) throws InterruptedException;
          E poll(long timeout, TimeUnit unit) throws InterruptedException;
      }
      public class LinkedBlockingQueue<E> extends AbstractCollection<E> implements BlockingQueue<E>, java.io.Serializable {
          public LinkedBlockingQueue() {}
          public LinkedBlockingQueue(int capacity) {}
          public int size();
          public void put(E e) throws InterruptedException;
          public boolean offer(E e, long timeout, TimeUnit unit) throws InterruptedException;
          public boolean offer(E e);
          public E take() throws InterruptedException;
          public E poll(long timeout, TimeUnit unit) throws InterruptedException;
          public E poll();
          public E peek();
          public boolean remove(Object o);
          public boolean contains(Object o);
          public void clear();
          public Iterator<E> iterator();
      }
      public class ArrayBlockingQueue<E> extends AbstractCollection<E> implements BlockingQueue<E>, java.io.Serializable { public ArrayBlockingQueue(int capacity) {} }
      public class CountDownLatch {
          public CountDownLatch(int count) {}
          public void await() throws InterruptedException;
          public boolean await(long timeout, TimeUnit unit) throws InterruptedException;
          public void countDown();
          public long getCount();
      }
      public class Semaphore implements java.io.Serializable {
          public Semaphore(int permits) {}
          public void acquire() throws InterruptedException;
          public void release();
          public boolean tryAcquire();
      }
      public class ExecutionException extends Exception { public ExecutionException(Throwable cause) {} public ExecutionException(String message, Throwable cause) {} }
      public class TimeoutException extends Exception { public TimeoutException() {} public TimeoutException(String message) {} }
      public class CancellationException extends IllegalStateException { public CancellationException() {} public CancellationException(String message) {} }
      public class CompletionException extends RuntimeException { public CompletionException(Throwable cause) {} public CompletionException(String message, Throwable cause) {} }
      """,
    "java/util/concurrent/atomic/atomic.java": """
      package java.util.concurrent.atomic;
      import java.util.function.*;
      public class AtomicBoolean implements java.io.Serializable {
          public AtomicBoolean() {}
          public AtomicBoolean(boolean initialValue) {}
          public final boolean get();
          public final void set(boolean newValue);
          public final boolean getAndSet(boolean newValue);
          public final boolean compareAndSet(boolean expectedValue, boolean newValue);
      }
      public class AtomicInteger extends Number implements java.io.Serializable {
          public AtomicInteger() {}
          public AtomicInteger(int initialValue) {}
          public final int get();
          public final void set(int newValue);
          public final int getAndSet(int newValue);
          public final boolean compareAndSet(int expectedValue, int newValue);
          public final int getAndIncrement();
          public final int getAndDecrement();
          public final int getAndAdd(int delta);
          public final int incrementAndGet();
          public final int decrementAndGet();
          public final int addAndGet(int delta);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
      }
      public class AtomicLong extends Number implements java.io.Serializable {
          public AtomicLong() {}
          public AtomicLong(long initialValue) {}
          public final long get();
          public final void set(long newValue);
          public final long getAndIncrement();
          public final long incrementAndGet();
          public final long addAndGet(long delta);
          public final long getAndAdd(long delta);
          public final boolean compareAndSet(long expectedValue, long newValue);
          public int intValue();
          public long longValue();
          public float floatValue();
          public double doubleValue();
      }
      public class AtomicReference<V> implements java.io.Serializable {
          public AtomicReference() {}
          public AtomicReference(V initialValue) {}
          public final V get();
          public final void set(V newValue);
          public final V getAndSet(V newValue);
          public final boolean compareAndSet(V expectedValue, V newValue);
          public final V updateAndGet(UnaryOperator<V> updateFunction);
      }
      """,
    "java/util/concurrent/locks/locks.java": """
      package java.util.concurrent.locks;
      public interface Lock {
          void lock();
          void unlock();
          boolean tryLock();
          Condition newCondition();
      }
      public interface Condition {
          void await() throws InterruptedException;
          void signal();
          void signalAll();
      }
      public class ReentrantLock implements Lock, java.io.Serializable {
          public ReentrantLock() {}
          public ReentrantLock(boolean fair) {}
          public void lock();
          public void unlock();
          public boolean tryLock();
          public Condition newCondition();
      }
      """,
    "java/io/io.java": """
      package java.io;
      import java.nio.charset.Charset;
      import java.nio.file.Path;
      public interface Serializable {}
      public interface Closeable extends AutoCloseable { void close() throws IOException; }
      public interface Flushable { void flush() throws IOException; }
      public class IOException extends Exception {
          public IOException() {}
          public IOException(String message) {}
          public IOException(String message, Throwable cause) {}
          public IOException(Throwable cause) {}
      }
      public class UncheckedIOException extends RuntimeException { public UncheckedIOException(String message, IOException cause) {} public UncheckedIOException(IOException cause) {} }
      public class FileNotFoundException extends IOException { public FileNotFoundException() {} public FileNotFoundException(String s) {} }
      public class EOFException extends IOException { public EOFException() {} public EOFException(String s) {} }
      public class UnsupportedEncodingException extends IOException { public UnsupportedEncodingException() {} public UnsupportedEncodingException(String s) {} }
      public abstract class InputStream implements Closeable {
          public InputStream() {}
          public abstract int read() throws IOException;
          public int read(byte[] b) throws IOException;
          public int read(byte[] b, int off, int len) throws IOException;
          public byte[] readAllBytes() throws IOException;
          public byte[] readNBytes(int len) throws IOException;
          public long skip(long n) throws IOException;
          public int available() throws IOException;
          public void close() throws IOException;
          public long transferTo(OutputStream out) throws IOException;
      }
      public abstract class OutputStream implements Closeable, Flushable {
          public OutputStream() {}
          public abstract void write(int b) throws IOException;
          public void write(byte[] b) throws IOException;
          public void write(byte[] b, int off, int len) throws IOException;
          public void flush() throws IOException;
          public void close() throws IOException;
      }
      public class ByteArrayInputStream extends InputStream {
          public ByteArrayInputStream(byte[] buf) {}
          public ByteArrayInputStream(byte[] buf, int offset, int length) {}
          public int read();
      }
      public class ByteArrayOutputStream extends OutputStream {
          public ByteArrayOutputStream() {}
          public ByteArrayOutputStream(int size) {}
          public void write(int b);
          public void writeBytes(byte[] b);
          public byte[] toByteArray();
          public int size();
          public void reset();
          public String toString();
          public String toString(Charset charset);
      }
      public class FileInputStream extends InputStream {
          public FileInputStream(String name) throws FileNotFoundException {}
          public FileInputStream(File file) throws FileNotFoundException {}
          public int read() throws IOException;
      }
      public class FileOutputStream extends OutputStream {
          public FileOutputStream(String name) throws FileNotFoundException {}
          public FileOutputStream(File file) throws FileNotFoundException {}
          public FileOutputStream(File file, boolean append) throws FileNotFoundException {}
          public void write(int b) throws IOException;
          public void write(byte[] b) throws IOException;
          public void write(byte[] b, int off, int len) throws IOException;
          public void close() throws IOException;
      }
      public class FilterInputStream extends InputStream { protected FilterInputStream(InputStream in) {} public int read() throws IOException; }
      public class FilterOutputStream extends OutputStream { public FilterOutputStream(OutputStream out) {} public void write(int b) throws IOException; }
      public class BufferedInputStream extends FilterInputStream { public BufferedInputStream(InputStream in) {} public BufferedInputStream(InputStream in, int size) {} }
      public class BufferedOutputStream extends FilterOutputStream { public BufferedOutputStream(OutputStream out) {} public BufferedOutputStream(OutputStream out, int size) {} }
      public class DataInputStream extends FilterInputStream {
          public DataInputStream(InputStream in) {}
          public final void readFully(byte[] b) throws IOException;
          public final int readInt() throws IOException;
          public final long readLong() throws IOException;
          public final String readUTF() throws IOException;
      }
      public class DataOutputStream extends FilterOutputStream {
          public DataOutputStream(OutputStream out) {}
          public final void writeInt(int v) throws IOException;
          public final void writeLong(long v) throws IOException;
          public final void writeUTF(String str) throws IOException;
      }
      public class PrintStream extends FilterOutputStream implements Appendable, Closeable {
          public PrintStream(OutputStream out) {}
          public PrintStream(OutputStream out, boolean autoFlush) {}
          public void print(String s);
          public void print(Object obj);
          public void print(int i);
          public void print(char c);
          public void println();
          public void println(String x);
          public void println(Object x);
          public void println(int x);
          public void println(long x);
          public void println(double x);
          public void println(boolean x);
          public void println(char x);
          public PrintStream printf(String format, Object... args);
          public PrintStream format(String format, Object... args);
          public void flush();
          public void close();
      }
      public abstract class Reader implements Readable, Closeable {
          protected Reader() {}
          public int read() throws IOException;
          public int read(char[] cbuf) throws IOException;
          public abstract int read(char[] cbuf, int off, int len) throws IOException;
          public abstract void close() throws IOException;
      }
      public abstract class Writer implements Appendable, Closeable, Flushable {
          protected Writer() {}
          public void write(int c) throws IOException;
          public void write(String str) throws IOException;
          public abstract void write(char[] cbuf, int off, int len) throws IOException;
          public Writer append(CharSequence csq) throws IOException;
          public abstract void flush() throws IOException;
          public abstract void close() throws IOException;
      }
      public class InputStreamReader extends Reader {
          public InputStreamReader(InputStream in) {}
          public InputStreamReader(InputStream in, Charset cs) {}
          public int read(char[] cbuf, int off, int len) throws IOException;
          public void close() throws IOException;
      }
      public class OutputStreamWriter extends Writer {
          public OutputStreamWriter(OutputStream out) {}
          public OutputStreamWriter(OutputStream out, Charset cs) {}
          public void write(char[] cbuf, int off, int len) throws IOException;
          public void flush() throws IOException;
          public void close() throws IOException;
      }
      public class BufferedReader extends Reader {
          public BufferedReader(Reader in) {}
          public BufferedReader(Reader in, int sz) {}
          public String readLine() throws IOException;
          public java.util.stream.Stream<String> lines();
          public int read(char[] cbuf, int off, int len) throws IOException;
          public void close() throws IOException;
      }
      public class BufferedWriter extends Writer {
          public BufferedWriter(Writer out) {}
          public void newLine() throws IOException;
          public void write(char[] cbuf, int off, int len) throws IOException;
          public void flush() throws IOException;
          public void close() throws IOException;
      }
      public class StringReader extends Reader { public StringReader(String s) {} public int read(char[] cbuf, int off, int len) throws IOException; public void close(); }
      public class StringWriter extends Writer { public StringWriter() {} public String toString(); public void write(char[] cbuf, int off, int len); public void flush(); public void close() throws IOException; }
      public class PrintWriter extends Writer {
          public PrintWriter(Writer out) {}
          public PrintWriter(OutputStream out) {}
          public void print(String s);
          public void println();
          public void println(String x);
          public void println(Object x);
          public PrintWriter printf(String format, Object... args);
          public void write(char[] buf, int off, int len);
          public void flush();
          public void close();
      }
      public class FileReader extends InputStreamReader { public FileReader(String fileName) throws FileNotFoundException {} public FileReader(File file) throws FileNotFoundException {} }
      public class FileWriter extends OutputStreamWriter { public FileWriter(String fileName) throws IOException {} public FileWriter(File file) throws IOException {} }
      public class File implements Serializable, Comparable<File> {
          public static final String separator;
          public File(String pathname) {}
          public File(String parent, String child) {}
          public File(File parent, String child) {}
          public String getName();
          public String getParent();
          public File getParentFile();
          public String getPath();
          public String getAbsolutePath();
          public File getAbsoluteFile();
          public String getCanonicalPath() throws IOException;
          public boolean exists();
          public boolean isDirectory();
          public boolean isFile();
          public long length();
          public long lastModified();
          public boolean delete();
          public boolean mkdir();
          public boolean mkdirs();
          public boolean createNewFile() throws IOException;
          public boolean renameTo(File dest);
          public String[] list();
          public File[] listFiles();
          public Path toPath();
          public int compareTo(File pathname);
          public static File createTempFile(String prefix, String suffix) throws IOException;
      }
      public interface Readable {}
      """,
    "java/nio/nio.java": """
      package java.nio;
      public abstract class Buffer {
          public final int capacity();
          public final int position();
          public Buffer position(int newPosition);
          public final int limit();
          public Buffer limit(int newLimit);
          public Buffer clear();
          public Buffer flip();
          public Buffer rewind();
          public final int remaining();
          public final boolean hasRemaining();
      }
      public abstract class ByteBuffer extends Buffer implements Comparable<ByteBuffer> {
          public static ByteBuffer allocate(int capacity);
          public static ByteBuffer allocateDirect(int capacity);
          public static ByteBuffer wrap(byte[] array);
          public static ByteBuffer wrap(byte[] array, int offset, int length);
          public abstract byte get();
          public abstract byte get(int index);
          public ByteBuffer get(byte[] dst);
          public ByteBuffer get(byte[] dst, int offset, int length);
          public abstract ByteBuffer put(byte b);
          public ByteBuffer put(byte[] src);
          public ByteBuffer put(byte[] src, int offset, int length);
          public ByteBuffer put(ByteBuffer src);
          public abstract int getInt();
          public abstract ByteBuffer putInt(int value);
          public abstract long getLong();
          public abstract ByteBuffer putLong(long value);
          public abstract short getShort();
          public abstract ByteBuffer putShort(short value);
          public final byte[] array();
          public final boolean hasArray();
          public abstract ByteBuffer slice();
          public abstract ByteBuffer duplicate();
          public abstract ByteBuffer compact();
          public final ByteOrder order();
          public final ByteBuffer order(ByteOrder bo);
          public ByteBuffer flip();
          public ByteBuffer clear();
          public ByteBuffer position(int newPosition);
          public ByteBuffer limit(int newLimit);
          public int compareTo(ByteBuffer that);
      }
      public final class ByteOrder {
          public static final ByteOrder BIG_ENDIAN;
          public static final ByteOrder LITTLE_ENDIAN;
          public static ByteOrder nativeOrder();
      }
      """,
    "java/nio/charset/charset.java": """
      package java.nio.charset;
      public abstract class Charset implements Comparable<Charset> {
          public static Charset forName(String charsetName);
          public static Charset defaultCharset();
          public final String name();
          public final int compareTo(Charset that);
      }
      public final class StandardCharsets {
          public static final Charset US_ASCII;
          public static final Charset ISO_8859_1;
          public static final Charset UTF_8;
          public static final Charset UTF_16;
      }
      """,
    "java/nio/file/file.java": """
      package java.nio.file;
      import java.io.*;
      import java.nio.charset.Charset;
      import java.util.*;
      import java.util.stream.Stream;
      public interface Path extends Comparable<Path>, Iterable<Path> {
          static Path of(String first, String... more);
          Path getFileName();
          Path getParent();
          Path getRoot();
          boolean isAbsolute();
          Path resolve(Path other);
          Path resolve(String other);
          Path resolveSibling(String other);
          Path relativize(Path other);
          Path normalize();
          Path toAbsolutePath();
          boolean startsWith(String other);
          boolean endsWith(String other);
          File toFile();
          String toString();
      }
      public final class Paths { public static Path get(String first, String... more); }
      public interface OpenOption {}
      public interface CopyOption {}
      public enum StandardOpenOption implements OpenOption { READ, WRITE, APPEND, TRUNCATE_EXISTING, CREATE, CREATE_NEW, DELETE_ON_CLOSE, SPARSE, SYNC, DSYNC }
      public enum StandardCopyOption implements CopyOption { REPLACE_EXISTING, COPY_ATTRIBUTES, ATOMIC_MOVE }
      public final class Files {
          public static boolean exists(Path path, LinkOption... options);
          public static boolean notExists(Path path, LinkOption... options);
          public static boolean isDirectory(Path path, LinkOption... options);
          public static boolean isRegularFile(Path path, LinkOption... options);
          public static long size(Path path) throws IOException;
          public static byte[] readAllBytes(Path path) throws IOException;
          public static String readString(Path path) throws IOException;
          public static String readString(Path path, Charset cs) throws IOException;
          public static List<String> readAllLines(Path path) throws IOException;
          public static Path write(Path path, byte[] bytes, OpenOption... options) throws IOException;
          public static Path writeString(Path path, CharSequence csq, OpenOption... options) throws IOException;
          public static Path writeString(Path path, CharSequence csq, Charset cs, OpenOption... options) throws IOException;
          public static Path createDirectories(Path dir) throws IOException;
          public static Path createDirectory(Path dir) throws IOException;
          public static Path createFile(Path path) throws IOException;
          public static Path createTempFile(String prefix, String suffix) throws IOException;
          public static Path createTempDirectory(String prefix) throws IOException;
          public static void delete(Path path) throws IOException;
          public static boolean deleteIfExists(Path path) throws IOException;
          public static Path copy(Path source, Path target, CopyOption... options) throws IOException;
          public static Path move(Path source, Path target, CopyOption... options) throws IOException;
          public static Stream<Path> list(Path dir) throws IOException;
          public static Stream<Path> walk(Path start) throws IOException;
          public static Stream<String> lines(Path path) throws IOException;
          public static InputStream newInputStream(Path path, OpenOption... options) throws IOException;
          public static OutputStream newOutputStream(Path path, OpenOption... options) throws IOException;
          public static BufferedReader newBufferedReader(Path path) throws IOException;
          public static BufferedWriter newBufferedWriter(Path path, OpenOption... options) throws IOException;
      }
      public enum LinkOption implements OpenOption, CopyOption { NOFOLLOW_LINKS }
      public class NoSuchFileException extends FileSystemException { public NoSuchFileException(String file) {} }
      public class FileSystemException extends IOException { public FileSystemException(String file) {} }
      """,
    "java/time/time.java": """
      package java.time;
      import java.time.temporal.*;
      public final class Duration implements TemporalAmount, Comparable<Duration>, java.io.Serializable {
          public static final Duration ZERO;
          public static Duration ofDays(long days);
          public static Duration ofHours(long hours);
          public static Duration ofMinutes(long minutes);
          public static Duration ofSeconds(long seconds);
          public static Duration ofMillis(long millis);
          public static Duration ofNanos(long nanos);
          public static Duration between(Temporal startInclusive, Temporal endExclusive);
          public long getSeconds();
          public long toMillis();
          public long toNanos();
          public long toSeconds();
          public boolean isZero();
          public boolean isNegative();
          public Duration plus(Duration duration);
          public Duration minus(Duration duration);
          public Duration plusMillis(long millisToAdd);
          public Duration multipliedBy(long multiplicand);
          public int compareTo(Duration otherDuration);
      }
      public final class Instant implements Temporal, Comparable<Instant>, java.io.Serializable {
          public static final Instant EPOCH;
          public static Instant now();
          public static Instant ofEpochMilli(long epochMilli);
          public static Instant ofEpochSecond(long epochSecond);
          public static Instant parse(CharSequence text);
          public long toEpochMilli();
          public long getEpochSecond();
          public Instant plus(Duration amount);
          public Instant minus(Duration amount);
          public Instant plusSeconds(long secondsToAdd);
          public Instant plusMillis(long millisToAdd);
          public boolean isAfter(Instant otherInstant);
          public boolean isBefore(Instant otherInstant);
          public int compareTo(Instant otherInstant);
      }
      public final class LocalDate implements Temporal, Comparable<LocalDate>, java.io.Serializable {
          public static LocalDate now();
          public static LocalDate of(int year, int month, int dayOfMonth);
          public static LocalDate parse(CharSequence text);
          public int getYear();
          public int getMonthValue();
          public int getDayOfMonth();
          public LocalDate plusDays(long daysToAdd);
          public int compareTo(LocalDate other);
      }
      public final class LocalDateTime implements Temporal, Comparable<LocalDateTime>, java.io.Serializable {
          public static LocalDateTime now();
          public static LocalDateTime parse(CharSequence text);
          public int compareTo(LocalDateTime other);
      }
      public abstract class ZoneId implements java.io.Serializable {
          public static ZoneId systemDefault();
          public static ZoneId of(String zoneId);
      }
      public final class ZoneOffset extends ZoneId implements Comparable<ZoneOffset> { public static final ZoneOffset UTC; public int compareTo(ZoneOffset other); }
      public abstract class Clock { public static Clock systemUTC(); public long millis(); public abstract Instant instant(); }
      """,
    "java/time/temporal/temporal.java": """
      package java.time.temporal;
      public interface TemporalAccessor {}
      public interface Temporal extends TemporalAccessor {}
      public interface TemporalAmount {}
      public interface TemporalUnit {}
      public enum ChronoUnit implements TemporalUnit { NANOS, MICROS, MILLIS, SECONDS, MINUTES, HOURS, HALF_DAYS, DAYS, WEEKS, MONTHS, YEARS }
      """,
    "java/net/net.java": """
      package java.net;
      import java.io.*;
      public final class URI implements Comparable<URI>, java.io.Serializable {
          public URI(String str) throws URISyntaxException {}
          public static URI create(String str);
          public String getScheme();
          public String getHost();
          public int getPort();
          public String getPath();
          public String getRawPath();
          public String getQuery();
          public String getRawQuery();
          public String getFragment();
          public URI resolve(String str);
          public URL toURL() throws MalformedURLException;
          public int compareTo(URI that);
      }
      public final class URL implements java.io.Serializable {
          public URL(String spec) throws MalformedURLException {}
          public URLConnection openConnection() throws IOException;
          public InputStream openStream() throws IOException;
          public String getHost();
          public String getPath();
          public URI toURI() throws URISyntaxException;
      }
      public abstract class URLConnection {
          public InputStream getInputStream() throws IOException;
          public OutputStream getOutputStream() throws IOException;
          public void setRequestProperty(String key, String value);
      }
      public abstract class HttpURLConnection extends URLConnection { public int getResponseCode() throws IOException; public void setRequestMethod(String method) throws ProtocolException; public void disconnect(); }
      public final class URLEncoder { public static String encode(String s, java.nio.charset.Charset charset); }
      public final class URLDecoder { public static String decode(String s, java.nio.charset.Charset charset); }
      public class URISyntaxException extends Exception { public URISyntaxException(String input, String reason) {} }
      public class MalformedURLException extends IOException { public MalformedURLException() {} public MalformedURLException(String msg) {} }
      public class ProtocolException extends IOException { public ProtocolException() {} public ProtocolException(String message) {} }
      public class SocketException extends IOException { public SocketException() {} public SocketException(String msg) {} }
      public class SocketTimeoutException extends java.io.InterruptedIOException { public SocketTimeoutException() {} public SocketTimeoutException(String msg) {} }
      public class ConnectException extends SocketException { public ConnectException() {} public ConnectException(String msg) {} }
      public abstract class SocketAddress implements java.io.Serializable {}
      public class InetSocketAddress extends SocketAddress {
          public InetSocketAddress(int port) {}
          public InetSocketAddress(String hostname, int port) {}
          public InetSocketAddress(InetAddress addr, int port) {}
          public final int getPort();
          public final String getHostName();
          public final String getHostString();
          public final InetAddress getAddress();
      }
      public class InetAddress implements java.io.Serializable {
          public static InetAddress getByName(String host) throws UnknownHostException;
          public static InetAddress getLocalHost() throws UnknownHostException;
          public static InetAddress getLoopbackAddress();
          public String getHostAddress();
          public String getHostName();
      }
      public class UnknownHostException extends IOException { public UnknownHostException() {} public UnknownHostException(String message) {} }
      public class Socket implements Closeable {
          public Socket() {}
          public Socket(String host, int port) throws UnknownHostException, IOException {}
          public void connect(SocketAddress endpoint) throws IOException;
          public void connect(SocketAddress endpoint, int timeout) throws IOException;
          public InputStream getInputStream() throws IOException;
          public OutputStream getOutputStream() throws IOException;
          public void setSoTimeout(int timeout) throws SocketException;
          public void setTcpNoDelay(boolean on) throws SocketException;
          public boolean isClosed();
          public boolean isConnected();
          public int getPort();
          public int getLocalPort();
          public void close() throws IOException;
      }
      public class ServerSocket implements Closeable {
          public ServerSocket() throws IOException {}
          public ServerSocket(int port) throws IOException {}
          public void bind(SocketAddress endpoint) throws IOException;
          public Socket accept() throws IOException;
          public int getLocalPort();
          public boolean isClosed();
          public void close() throws IOException;
      }
      """,
    "java/io/InterruptedIOException.java": """
      package java.io;
      public class InterruptedIOException extends IOException { public InterruptedIOException() {} public InterruptedIOException(String s) {} }
      """,
  ]
}
