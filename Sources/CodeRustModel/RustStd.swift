import Foundation

/// A hand-written stub of Rust's standard library (std, core and alloc are one crate here): no rust-src is installed on
/// this Mac, so the declarations code uses most are written out with their signatures, for the model to read; written
/// to `$TMPDIR/code-rust-std/std.rs` so that ⌘-click can open it. Chosen by how often the corpora's code uses each item
/// (rustdoc's links over session, hub-service-rs, channel-rs and tokio). Left out: bodies, private items, most of the
/// less used modules (`simd`, `intrinsics`, `alloc::alloc` beyond `Layout`, `ascii`, `backtrace`, `f16`…), most
/// trait impls between std types, and what a macro expands to.
enum RustStd {
  static let source: String = header + modules + integers + floats + macros

  private static let header = #"""
    //! CodeRustModel's stub of the Rust standard library (std, core and alloc as one crate), hand-written for reading:
    //! no rust-src is installed. Signatures only; not the real library.
    #![allow(all)]

    pub mod prelude {
        pub use crate::option::Option::{self, Some, None};
        pub use crate::result::Result::{self, Ok, Err};
        pub use crate::string::{String, ToString};
        pub use crate::vec::Vec;
        pub use crate::boxed::Box;
        pub use crate::clone::Clone;
        pub use crate::marker::{Copy, Send, Sized, Sync, Unpin};
        pub use crate::ops::{Drop, Fn, FnMut, FnOnce, AsyncFn, AsyncFnMut, AsyncFnOnce};
        pub use crate::mem::{drop, size_of, size_of_val, align_of, align_of_val};
        pub use crate::convert::{From, Into, TryFrom, TryInto, AsRef, AsMut};
        pub use crate::default::Default;
        pub use crate::iter::{Iterator, IntoIterator, Extend, DoubleEndedIterator, ExactSizeIterator, FromIterator};
        pub use crate::cmp::{PartialEq, Eq, PartialOrd, Ord};
        pub use crate::borrow::ToOwned;
        pub use crate::future::{Future, IntoFuture};
        pub use crate::fmt::Debug;
        pub use crate::hash::Hash;
    }

    pub mod primitive {
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct bool;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct char;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, PartialOrd)] pub struct f32;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, PartialOrd)] pub struct f64;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct i8;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct i16;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct i32;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct i64;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct i128;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct isize;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct u8;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct u16;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct u32;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct u64;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct u128;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct usize;
        #[derive(Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct str;

        impl bool {
            pub fn then<T, F: FnOnce() -> T>(self, f: F) -> Option<T>;
            pub fn then_some<T>(self, t: T) -> Option<T>;
        }
        impl char {
            pub const MAX: char;
            pub fn is_alphabetic(self) -> bool; pub fn is_numeric(self) -> bool; pub fn is_alphanumeric(self) -> bool;
            pub fn is_whitespace(self) -> bool; pub fn is_control(self) -> bool; pub fn is_ascii(&self) -> bool;
            pub fn is_ascii_digit(&self) -> bool; pub fn is_ascii_alphabetic(&self) -> bool; pub fn is_ascii_alphanumeric(&self) -> bool;
            pub fn is_ascii_whitespace(&self) -> bool; pub fn is_ascii_uppercase(&self) -> bool; pub fn is_ascii_lowercase(&self) -> bool;
            pub fn is_ascii_punctuation(&self) -> bool; pub fn is_ascii_hexdigit(&self) -> bool; pub fn is_ascii_graphic(&self) -> bool;
            pub fn is_uppercase(self) -> bool; pub fn is_lowercase(self) -> bool;
            pub fn to_ascii_lowercase(&self) -> char; pub fn to_ascii_uppercase(&self) -> char;
            pub fn to_lowercase(self) -> ToLowercase; pub fn to_uppercase(self) -> ToUppercase;
            pub fn to_digit(self, radix: u32) -> Option<u32>; pub fn from_u32(i: u32) -> Option<char>; pub fn from_digit(num: u32, radix: u32) -> Option<char>;
            pub fn len_utf8(self) -> usize; pub fn encode_utf8(self, dst: &mut [u8]) -> &mut str; pub fn eq_ignore_ascii_case(&self, other: &char) -> bool;
        }
        pub struct ToLowercase; pub struct ToUppercase;
        impl Iterator for ToLowercase { type Item = char; }
        impl Iterator for ToUppercase { type Item = char; }

        impl str {
            pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn as_bytes(&self) -> &[u8]; pub fn as_ptr(&self) -> *const u8;
            pub fn bytes(&self) -> Bytes<'_>; pub fn chars(&self) -> Chars<'_>; pub fn char_indices(&self) -> CharIndices<'_>; pub fn lines(&self) -> Lines<'_>;
            pub fn split<P>(&self, pat: P) -> Split<'_, P>; pub fn splitn<P>(&self, n: usize, pat: P) -> Split<'_, P>; pub fn rsplit<P>(&self, pat: P) -> Split<'_, P>;
            pub fn rsplitn<P>(&self, n: usize, pat: P) -> Split<'_, P>; pub fn split_terminator<P>(&self, pat: P) -> Split<'_, P>;
            pub fn split_whitespace(&self) -> SplitWhitespace<'_>; pub fn split_ascii_whitespace(&self) -> SplitWhitespace<'_>;
            pub fn split_once<P>(&self, delimiter: P) -> Option<(&str, &str)>; pub fn rsplit_once<P>(&self, delimiter: P) -> Option<(&str, &str)>;
            pub fn split_at(&self, mid: usize) -> (&str, &str);
            pub fn trim(&self) -> &str; pub fn trim_start(&self) -> &str; pub fn trim_end(&self) -> &str;
            pub fn trim_matches<P>(&self, pat: P) -> &str; pub fn trim_start_matches<P>(&self, pat: P) -> &str; pub fn trim_end_matches<P>(&self, pat: P) -> &str;
            pub fn starts_with<P>(&self, pat: P) -> bool; pub fn ends_with<P>(&self, pat: P) -> bool; pub fn contains<P>(&self, pat: P) -> bool;
            pub fn find<P>(&self, pat: P) -> Option<usize>; pub fn rfind<P>(&self, pat: P) -> Option<usize>; pub fn matches<P>(&self, pat: P) -> Matches<'_, P>;
            pub fn strip_prefix<P>(&self, prefix: P) -> Option<&str>; pub fn strip_suffix<P>(&self, suffix: P) -> Option<&str>;
            pub fn replace<P>(&self, from: P, to: &str) -> String; pub fn replacen<P>(&self, pat: P, to: &str, count: usize) -> String;
            pub fn to_lowercase(&self) -> String; pub fn to_uppercase(&self) -> String; pub fn to_ascii_lowercase(&self) -> String; pub fn to_ascii_uppercase(&self) -> String;
            pub fn repeat(&self, n: usize) -> String; pub fn parse<F: FromStr>(&self) -> Result<F, F::Err>; pub fn get<I>(&self, i: I) -> Option<&str>;
            pub fn is_char_boundary(&self, index: usize) -> bool; pub fn eq_ignore_ascii_case(&self, other: &str) -> bool; pub fn is_ascii(&self) -> bool;
            pub fn into_string(self: Box<str>) -> String; pub fn as_mut_ptr(&mut self) -> *mut u8; pub fn char_count(&self) -> usize;
            pub fn encode_utf16(&self) -> EncodeUtf16<'_>; pub fn escape_debug(&self) -> String; pub fn escape_default(&self) -> String;
        }
        impl ToOwned for str { type Owned = String; }
        impl AsRef<str> for str {} impl AsRef<[u8]> for str {} impl AsRef<Path> for str {} impl AsRef<OsStr> for str {}
        pub struct Bytes<'a>; pub struct Chars<'a>; pub struct CharIndices<'a>; pub struct Lines<'a>; pub struct Split<'a, P>;
        pub struct SplitWhitespace<'a>; pub struct Matches<'a, P>; pub struct EncodeUtf16<'a>;
        impl<'a> Iterator for Bytes<'a> { type Item = u8; }
        impl<'a> Iterator for Chars<'a> { type Item = char; }
        impl<'a> Chars<'a> { pub fn as_str(&self) -> &'a str; }
        impl<'a> Iterator for CharIndices<'a> { type Item = (usize, char); }
        impl<'a> Iterator for Lines<'a> { type Item = &'a str; }
        impl<'a, P> Iterator for Split<'a, P> { type Item = &'a str; }
        impl<'a> Iterator for SplitWhitespace<'a> { type Item = &'a str; }
        impl<'a, P> Iterator for Matches<'a, P> { type Item = &'a str; }
        impl<'a> Iterator for EncodeUtf16<'a> { type Item = u16; }
        impl<'a> DoubleEndedIterator for Chars<'a> {} impl<'a> DoubleEndedIterator for Bytes<'a> {}

        impl<T> [T] {
            pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn iter(&self) -> Iter<'_, T>; pub fn iter_mut(&mut self) -> IterMut<'_, T>;
            pub fn first(&self) -> Option<&T>; pub fn last(&self) -> Option<&T>; pub fn first_mut(&mut self) -> Option<&mut T>; pub fn last_mut(&mut self) -> Option<&mut T>;
            pub fn get<I>(&self, index: I) -> Option<&T>; pub fn get_mut<I>(&mut self, index: I) -> Option<&mut T>;
            pub unsafe fn get_unchecked<I>(&self, index: I) -> &T; pub unsafe fn get_unchecked_mut<I>(&mut self, index: I) -> &mut T;
            pub fn to_vec(&self) -> Vec<T> where T: Clone; pub fn into_vec(self: Box<Self>) -> Vec<T>; pub fn contains(&self, x: &T) -> bool where T: PartialEq;
            pub fn starts_with(&self, needle: &[T]) -> bool where T: PartialEq; pub fn ends_with(&self, needle: &[T]) -> bool where T: PartialEq;
            pub fn strip_prefix(&self, prefix: &[T]) -> Option<&[T]>; pub fn strip_suffix(&self, suffix: &[T]) -> Option<&[T]>;
            pub fn split_at(&self, mid: usize) -> (&[T], &[T]); pub fn split_at_mut(&mut self, mid: usize) -> (&mut [T], &mut [T]);
            pub fn split_first(&self) -> Option<(&T, &[T])>; pub fn split_last(&self) -> Option<(&T, &[T])>;
            pub fn chunks(&self, chunk_size: usize) -> Chunks<'_, T>; pub fn chunks_exact(&self, chunk_size: usize) -> Chunks<'_, T>; pub fn windows(&self, size: usize) -> Windows<'_, T>;
            pub fn sort(&mut self) where T: Ord; pub fn sort_unstable(&mut self) where T: Ord; pub fn sort_by<F>(&mut self, compare: F) where F: FnMut(&T, &T) -> Ordering;
            pub fn sort_by_key<K, F>(&mut self, f: F) where F: FnMut(&T) -> K, K: Ord; pub fn sort_unstable_by_key<K, F>(&mut self, f: F) where F: FnMut(&T) -> K, K: Ord;
            pub fn sort_unstable_by<F>(&mut self, compare: F) where F: FnMut(&T, &T) -> Ordering;
            pub fn binary_search(&self, x: &T) -> Result<usize, usize> where T: Ord; pub fn reverse(&mut self); pub fn swap(&mut self, a: usize, b: usize);
            pub fn copy_from_slice(&mut self, src: &[T]) where T: Copy; pub fn clone_from_slice(&mut self, src: &[T]) where T: Clone; pub fn fill(&mut self, value: T) where T: Clone;
            pub fn as_ptr(&self) -> *const T; pub fn as_mut_ptr(&mut self) -> *mut T; pub fn join<S>(&self, sep: S) -> String; pub fn concat(&self) -> Vec<T>;
            pub fn iter_rev(&self) -> Iter<'_, T>; pub fn rotate_left(&mut self, mid: usize); pub fn position<P>(&self, predicate: P) -> Option<usize>;
            pub fn to_ascii_lowercase(&self) -> Vec<u8>; pub fn is_ascii(&self) -> bool; pub fn repeat(&self, n: usize) -> Vec<T>;
            pub fn split<F>(&self, pred: F) -> Chunks<'_, T> where F: FnMut(&T) -> bool; pub fn last_chunk<const N: usize>(&self) -> Option<&[T; N]>;
        }
        impl<T: Clone> ToOwned for [T] { type Owned = Vec<T>; }
        impl<T> AsRef<[T]> for [T] {}
        impl<T, I> Index<I> for [T] { type Output = T; }
        impl<'a, T> IntoIterator for &'a [T] { type Item = &'a T; type IntoIter = Iter<'a, T>; }
        impl<'a, T> IntoIterator for &'a mut [T] { type Item = &'a mut T; type IntoIter = IterMut<'a, T>; }
        pub struct Iter<'a, T>; pub struct IterMut<'a, T>; pub struct Chunks<'a, T>; pub struct Windows<'a, T>;
        impl<'a, T> Iterator for Iter<'a, T> { type Item = &'a T; }
        impl<'a, T> DoubleEndedIterator for Iter<'a, T> {}
        impl<'a, T> ExactSizeIterator for Iter<'a, T> {}
        impl<'a, T> Iter<'a, T> { pub fn as_slice(&self) -> &'a [T]; }
        impl<'a, T> Iterator for IterMut<'a, T> { type Item = &'a mut T; }
        impl<'a, T> Iterator for Chunks<'a, T> { type Item = &'a [T]; }
        impl<'a, T> Iterator for Windows<'a, T> { type Item = &'a [T]; }

        impl<T, const N: usize> [T; N] {
            pub fn map<F, U>(self, f: F) -> [U; N] where F: FnMut(T) -> U; pub fn as_slice(&self) -> &[T]; pub fn as_mut_slice(&mut self) -> &mut [T];
        }
        impl<T, const N: usize> IntoIterator for [T; N] { type Item = T; type IntoIter = array::IntoIter<T, N>; }
        impl<'a, T, const N: usize> IntoIterator for &'a [T; N] { type Item = &'a T; type IntoIter = Iter<'a, T>; }

        impl<T: ?Sized> *const T {
            pub fn is_null(self) -> bool; pub fn cast<U>(self) -> *const U; pub fn cast_mut(self) -> *mut T; pub unsafe fn as_ref<'a>(self) -> Option<&'a T>;
            pub unsafe fn add(self, count: usize) -> *const T; pub unsafe fn sub(self, count: usize) -> *const T; pub unsafe fn offset(self, count: isize) -> *const T;
            pub unsafe fn offset_from(self, origin: *const T) -> isize; pub unsafe fn read(self) -> T; pub fn wrapping_add(self, count: usize) -> *const T;
            pub unsafe fn copy_to_nonoverlapping(self, dest: *mut T, count: usize); pub fn addr(self) -> usize;
        }
        impl<T: ?Sized> *mut T {
            pub fn is_null(self) -> bool; pub fn cast<U>(self) -> *mut U; pub fn cast_const(self) -> *const T; pub unsafe fn as_ref<'a>(self) -> Option<&'a T>;
            pub unsafe fn as_mut<'a>(self) -> Option<&'a mut T>; pub unsafe fn add(self, count: usize) -> *mut T; pub unsafe fn sub(self, count: usize) -> *mut T;
            pub unsafe fn offset(self, count: isize) -> *mut T; pub unsafe fn offset_from(self, origin: *const T) -> isize; pub unsafe fn read(self) -> T;
            pub unsafe fn write(self, val: T); pub unsafe fn write_bytes(self, val: u8, count: usize); pub unsafe fn copy_from_nonoverlapping(self, src: *const T, count: usize);
            pub unsafe fn copy_to_nonoverlapping(self, dest: *mut T, count: usize); pub fn wrapping_add(self, count: usize) -> *mut T; pub unsafe fn replace(self, src: T) -> T;
            pub fn addr(self) -> usize;
        }
        impl<T: ?Sized> Deref for &T { type Target = T; }
        impl<T: ?Sized> Deref for &mut T { type Target = T; }
        impl<T: ?Sized> Clone for &T {}
        impl<T: ?Sized> Copy for &T {}
    }

    """#

  private static let modules = #"""
    pub mod option {
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Option<T> { None, Some(T) }
        impl<T> Option<T> {
            pub fn is_some(&self) -> bool; pub fn is_none(&self) -> bool; pub fn is_some_and(self, f: impl FnOnce(T) -> bool) -> bool;
            pub fn is_none_or(self, f: impl FnOnce(T) -> bool) -> bool; pub fn as_ref(&self) -> Option<&T>; pub fn as_mut(&mut self) -> Option<&mut T>;
            pub fn as_pin_mut(self: Pin<&mut Self>) -> Option<Pin<&mut T>>; pub fn as_pin_ref(self: Pin<&Self>) -> Option<Pin<&T>>;
            pub fn expect(self, msg: &str) -> T; pub fn unwrap(self) -> T; pub fn unwrap_or(self, default: T) -> T;
            pub fn unwrap_or_else<F: FnOnce() -> T>(self, f: F) -> T; pub fn unwrap_or_default(self) -> T where T: Default; pub unsafe fn unwrap_unchecked(self) -> T;
            pub fn map<U, F: FnOnce(T) -> U>(self, f: F) -> Option<U>; pub fn inspect<F: FnOnce(&T)>(self, f: F) -> Self;
            pub fn map_or<U, F: FnOnce(T) -> U>(self, default: U, f: F) -> U; pub fn map_or_else<U, D: FnOnce() -> U, F: FnOnce(T) -> U>(self, default: D, f: F) -> U;
            pub fn ok_or<E>(self, err: E) -> Result<T, E>; pub fn ok_or_else<E, F: FnOnce() -> E>(self, err: F) -> Result<T, E>;
            pub fn iter(&self) -> Iter<'_, T>; pub fn and<U>(self, optb: Option<U>) -> Option<U>; pub fn and_then<U, F: FnOnce(T) -> Option<U>>(self, f: F) -> Option<U>;
            pub fn filter<P: FnOnce(&T) -> bool>(self, predicate: P) -> Self; pub fn or(self, optb: Option<T>) -> Option<T>; pub fn or_else<F: FnOnce() -> Option<T>>(self, f: F) -> Option<T>;
            pub fn xor(self, optb: Option<T>) -> Option<T>; pub fn insert(&mut self, value: T) -> &mut T; pub fn get_or_insert(&mut self, value: T) -> &mut T;
            pub fn get_or_insert_with<F: FnOnce() -> T>(&mut self, f: F) -> &mut T; pub fn take(&mut self) -> Option<T>; pub fn take_if<P>(&mut self, predicate: P) -> Option<T>;
            pub fn replace(&mut self, value: T) -> Option<T>; pub fn zip<U>(self, other: Option<U>) -> Option<(T, U)>;
        }
        impl<T: Deref> Option<T> { pub fn as_deref(&self) -> Option<&T::Target>; }
        impl<T: DerefMut> Option<T> { pub fn as_deref_mut(&mut self) -> Option<&mut T::Target>; }
        impl<T: Clone> Option<&T> { pub fn cloned(self) -> Option<T>; }
        impl<T: Copy> Option<&T> { pub fn copied(self) -> Option<T>; }
        impl<T> Option<Option<T>> { pub fn flatten(self) -> Option<T>; }
        impl<T, E> Option<Result<T, E>> { pub fn transpose(self) -> Result<Option<T>, E>; }
        impl<T> IntoIterator for Option<T> { type Item = T; type IntoIter = IntoIter<T>; }
        pub struct Iter<'a, A>; pub struct IntoIter<A>;
        impl<'a, A> Iterator for Iter<'a, A> { type Item = &'a A; }
        impl<A> Iterator for IntoIter<A> { type Item = A; }
    }

    pub mod result {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Result<T, E> { Ok(T), Err(E) }
        impl<T, E> Result<T, E> {
            pub fn is_ok(&self) -> bool; pub fn is_err(&self) -> bool; pub fn is_ok_and(self, f: impl FnOnce(T) -> bool) -> bool;
            pub fn is_err_and(self, f: impl FnOnce(E) -> bool) -> bool; pub fn ok(self) -> Option<T>; pub fn err(self) -> Option<E>;
            pub fn as_ref(&self) -> Result<&T, &E>; pub fn as_mut(&mut self) -> Result<&mut T, &mut E>;
            pub fn map<U, F: FnOnce(T) -> U>(self, op: F) -> Result<U, E>; pub fn map_or<U, F: FnOnce(T) -> U>(self, default: U, f: F) -> U;
            pub fn map_or_else<U, D: FnOnce(E) -> U, F: FnOnce(T) -> U>(self, default: D, f: F) -> U; pub fn map_err<F, O: FnOnce(E) -> F>(self, op: O) -> Result<T, F>;
            pub fn inspect<F: FnOnce(&T)>(self, f: F) -> Self; pub fn inspect_err<F: FnOnce(&E)>(self, f: F) -> Self; pub fn iter(&self) -> Iter<'_, T>;
            pub fn expect(self, msg: &str) -> T where E: Debug; pub fn unwrap(self) -> T where E: Debug; pub fn unwrap_or_default(self) -> T where T: Default;
            pub fn expect_err(self, msg: &str) -> E where T: Debug; pub fn unwrap_err(self) -> E where T: Debug;
            pub fn and<U>(self, res: Result<U, E>) -> Result<U, E>; pub fn and_then<U, F: FnOnce(T) -> Result<U, E>>(self, op: F) -> Result<U, E>;
            pub fn or<F>(self, res: Result<T, F>) -> Result<T, F>; pub fn or_else<F, O: FnOnce(E) -> Result<T, F>>(self, op: O) -> Result<T, F>;
            pub fn unwrap_or(self, default: T) -> T; pub fn unwrap_or_else<F: FnOnce(E) -> T>(self, op: F) -> T; pub unsafe fn unwrap_unchecked(self) -> T;
        }
        impl<T: Deref, E> Result<T, E> { pub fn as_deref(&self) -> Result<&T::Target, &E>; }
        impl<T, E> Result<Option<T>, E> { pub fn transpose(self) -> Option<Result<T, E>>; }
        impl<T, E> IntoIterator for Result<T, E> { type Item = T; type IntoIter = IntoIter<T>; }
        pub struct Iter<'a, T>; pub struct IntoIter<T>;
        impl<'a, T> Iterator for Iter<'a, T> { type Item = &'a T; }
        impl<T> Iterator for IntoIter<T> { type Item = T; }
    }

    pub mod borrow {
        pub trait Borrow<Borrowed: ?Sized> { fn borrow(&self) -> &Borrowed; }
        pub trait BorrowMut<Borrowed: ?Sized>: Borrow<Borrowed> { fn borrow_mut(&mut self) -> &mut Borrowed; }
        pub trait ToOwned { type Owned; fn to_owned(&self) -> Self::Owned; fn clone_into(&self, target: &mut Self::Owned); }
        impl<T: Clone> ToOwned for T { type Owned = T; }
        #[derive(Clone, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Cow<'a, B: ?Sized + 'a> { Borrowed(&'a B), Owned(<B as ToOwned>::Owned) }
        impl<B: ?Sized + ToOwned> Cow<'_, B> { pub fn into_owned(self) -> <B as ToOwned>::Owned; pub fn to_mut(&mut self) -> &mut <B as ToOwned>::Owned; pub fn is_borrowed(&self) -> bool; pub fn is_owned(&self) -> bool; }
        impl<B: ?Sized + ToOwned> Deref for Cow<'_, B> { type Target = B; }
    }

    pub mod clone { pub trait Clone: Sized { fn clone(&self) -> Self; fn clone_from(&mut self, source: &Self); } }
    pub mod default { pub trait Default: Sized { fn default() -> Self; } }

    pub mod marker {
        pub trait Copy: Clone {} pub trait Send {} pub trait Sync {} pub trait Sized {} pub trait Unpin {}
        pub trait Unsize<T: ?Sized> {} pub trait StructuralPartialEq {}
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct PhantomData<T: ?Sized>;
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct PhantomPinned;
    }

    pub mod convert {
        pub trait From<T>: Sized { fn from(value: T) -> Self; }
        pub trait Into<T>: Sized { fn into(self) -> T; }
        pub trait TryFrom<T>: Sized { type Error; fn try_from(value: T) -> Result<Self, Self::Error>; }
        pub trait TryInto<T>: Sized { type Error; fn try_into(self) -> Result<T, Self::Error>; }
        pub trait AsRef<T: ?Sized> { fn as_ref(&self) -> &T; }
        pub trait AsMut<T: ?Sized> { fn as_mut(&mut self) -> &mut T; }
        impl<T, U: From<T>> Into<U> for T {}
        impl<T> From<T> for T {}
        impl<T, U: Into<T>> TryFrom<U> for T { type Error = Infallible; }
        impl<T, U: TryFrom<T>> TryInto<U> for T { type Error = U::Error; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub enum Infallible {}
        pub fn identity<T>(x: T) -> T;
    }

    pub mod cmp {
        pub trait PartialEq<Rhs: ?Sized = Self> { fn eq(&self, other: &Rhs) -> bool; fn ne(&self, other: &Rhs) -> bool; }
        pub trait Eq: PartialEq<Self> {}
        pub trait PartialOrd<Rhs: ?Sized = Self>: PartialEq<Rhs> {
            fn partial_cmp(&self, other: &Rhs) -> Option<Ordering>; fn lt(&self, other: &Rhs) -> bool; fn le(&self, other: &Rhs) -> bool;
            fn gt(&self, other: &Rhs) -> bool; fn ge(&self, other: &Rhs) -> bool;
        }
        pub trait Ord: Eq + PartialOrd<Self> { fn cmp(&self, other: &Self) -> Ordering; fn max(self, other: Self) -> Self; fn min(self, other: Self) -> Self; fn clamp(self, min: Self, max: Self) -> Self; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Ordering { Less, Equal, Greater }
        impl Ordering {
            pub fn is_eq(self) -> bool; pub fn is_ne(self) -> bool; pub fn is_lt(self) -> bool; pub fn is_gt(self) -> bool; pub fn is_le(self) -> bool; pub fn is_ge(self) -> bool;
            pub fn reverse(self) -> Ordering; pub fn then(self, other: Ordering) -> Ordering; pub fn then_with<F: FnOnce() -> Ordering>(self, f: F) -> Ordering;
        }
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Reverse<T>(pub T);
        pub fn min<T: Ord>(v1: T, v2: T) -> T; pub fn max<T: Ord>(v1: T, v2: T) -> T;
        pub fn min_by_key<T, F: FnMut(&T) -> K, K: Ord>(v1: T, v2: T, f: F) -> T; pub fn max_by_key<T, F: FnMut(&T) -> K, K: Ord>(v1: T, v2: T, f: F) -> T;
    }

    pub mod hash {
        pub trait Hash { fn hash<H: Hasher>(&self, state: &mut H); }
        pub trait Hasher { fn finish(&self) -> u64; fn write(&mut self, bytes: &[u8]); fn write_u8(&mut self, i: u8); fn write_u32(&mut self, i: u32); fn write_u64(&mut self, i: u64); fn write_usize(&mut self, i: usize); }
        pub trait BuildHasher { type Hasher: Hasher; fn build_hasher(&self) -> Self::Hasher; fn hash_one<T: Hash>(&self, x: T) -> u64; }
        pub use crate::collections::hash_map::{RandomState, DefaultHasher};
        #[derive(Clone, Debug, Default)] pub struct BuildHasherDefault<H>;
    }

    pub mod ops {
        pub trait Deref { type Target: ?Sized; fn deref(&self) -> &Self::Target; }
        pub trait DerefMut: Deref { fn deref_mut(&mut self) -> &mut Self::Target; }
        pub trait Drop { fn drop(&mut self); }
        pub trait FnOnce<Args> { type Output; fn call_once(self, args: Args) -> Self::Output; }
        pub trait FnMut<Args>: FnOnce<Args> { fn call_mut(&mut self, args: Args) -> Self::Output; }
        pub trait Fn<Args>: FnMut<Args> { fn call(&self, args: Args) -> Self::Output; }
        pub trait AsyncFnOnce<Args> { type Output; } pub trait AsyncFnMut<Args>: AsyncFnOnce<Args> {} pub trait AsyncFn<Args>: AsyncFnMut<Args> {}
        pub trait Add<Rhs = Self> { type Output; fn add(self, rhs: Rhs) -> Self::Output; }
        pub trait Sub<Rhs = Self> { type Output; fn sub(self, rhs: Rhs) -> Self::Output; }
        pub trait Mul<Rhs = Self> { type Output; fn mul(self, rhs: Rhs) -> Self::Output; }
        pub trait Div<Rhs = Self> { type Output; fn div(self, rhs: Rhs) -> Self::Output; }
        pub trait Rem<Rhs = Self> { type Output; fn rem(self, rhs: Rhs) -> Self::Output; }
        pub trait Neg { type Output; fn neg(self) -> Self::Output; }
        pub trait Not { type Output; fn not(self) -> Self::Output; }
        pub trait BitAnd<Rhs = Self> { type Output; fn bitand(self, rhs: Rhs) -> Self::Output; }
        pub trait BitOr<Rhs = Self> { type Output; fn bitor(self, rhs: Rhs) -> Self::Output; }
        pub trait BitXor<Rhs = Self> { type Output; fn bitxor(self, rhs: Rhs) -> Self::Output; }
        pub trait Shl<Rhs = Self> { type Output; fn shl(self, rhs: Rhs) -> Self::Output; }
        pub trait Shr<Rhs = Self> { type Output; fn shr(self, rhs: Rhs) -> Self::Output; }
        pub trait AddAssign<Rhs = Self> { fn add_assign(&mut self, rhs: Rhs); } pub trait SubAssign<Rhs = Self> { fn sub_assign(&mut self, rhs: Rhs); }
        pub trait MulAssign<Rhs = Self> { fn mul_assign(&mut self, rhs: Rhs); } pub trait DivAssign<Rhs = Self> { fn div_assign(&mut self, rhs: Rhs); }
        pub trait BitAndAssign<Rhs = Self> { fn bitand_assign(&mut self, rhs: Rhs); } pub trait BitOrAssign<Rhs = Self> { fn bitor_assign(&mut self, rhs: Rhs); }
        pub trait BitXorAssign<Rhs = Self> { fn bitxor_assign(&mut self, rhs: Rhs); } pub trait ShlAssign<Rhs = Self> { fn shl_assign(&mut self, rhs: Rhs); }
        pub trait ShrAssign<Rhs = Self> { fn shr_assign(&mut self, rhs: Rhs); } pub trait RemAssign<Rhs = Self> { fn rem_assign(&mut self, rhs: Rhs); }
        pub trait Index<Idx: ?Sized> { type Output: ?Sized; fn index(&self, index: Idx) -> &Self::Output; }
        pub trait IndexMut<Idx: ?Sized>: Index<Idx> { fn index_mut(&mut self, index: Idx) -> &mut Self::Output; }
        pub trait RangeBounds<T: ?Sized> { fn start_bound(&self) -> Bound<&T>; fn end_bound(&self) -> Bound<&T>; fn contains<U: ?Sized>(&self, item: &U) -> bool; }
        #[derive(Clone, Default, Debug, PartialEq, Eq, Hash)] pub struct Range<Idx> { pub start: Idx, pub end: Idx }
        impl<Idx> Range<Idx> { pub fn contains<U: ?Sized>(&self, item: &U) -> bool; pub fn is_empty(&self) -> bool; }
        impl<A> Iterator for Range<A> { type Item = A; }
        impl<A> DoubleEndedIterator for Range<A> {}
        #[derive(Clone, Debug, PartialEq, Eq, Hash)] pub struct RangeInclusive<Idx>;
        impl<Idx> RangeInclusive<Idx> { pub const fn new(start: Idx, end: Idx) -> Self; pub const fn start(&self) -> &Idx; pub const fn end(&self) -> &Idx; pub fn contains<U: ?Sized>(&self, item: &U) -> bool; pub fn is_empty(&self) -> bool; pub fn into_inner(self) -> (Idx, Idx); }
        impl<A> Iterator for RangeInclusive<A> { type Item = A; }
        impl<A> DoubleEndedIterator for RangeInclusive<A> {}
        #[derive(Clone, Copy, Default, Debug, PartialEq, Eq, Hash)] pub struct RangeFull;
        #[derive(Clone, Debug, PartialEq, Eq, Hash)] pub struct RangeFrom<Idx> { pub start: Idx }
        impl<A> Iterator for RangeFrom<A> { type Item = A; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)] pub struct RangeTo<Idx> { pub end: Idx }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)] pub enum Bound<T> { Included(T), Excluded(T), Unbounded }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)] pub enum ControlFlow<B, C = ()> { Continue(C), Break(B) }
        impl<B, C> ControlFlow<B, C> { pub fn is_break(&self) -> bool; pub fn is_continue(&self) -> bool; pub fn break_value(self) -> Option<B>; }
    }

    pub mod iter {
        pub trait Iterator {
            type Item;
            fn next(&mut self) -> Option<Self::Item>;
            fn size_hint(&self) -> (usize, Option<usize>); fn count(self) -> usize where Self: Sized; fn last(self) -> Option<Self::Item> where Self: Sized;
            fn advance_by(&mut self, n: usize) -> Result<(), NonZero<usize>>; fn nth(&mut self, n: usize) -> Option<Self::Item>;
            fn step_by(self, step: usize) -> StepBy<Self> where Self: Sized;
            fn chain<U>(self, other: U) -> Chain<Self, U::IntoIter> where Self: Sized, U: IntoIterator<Item = Self::Item>;
            fn zip<U>(self, other: U) -> Zip<Self, U::IntoIter> where Self: Sized, U: IntoIterator;
            fn map<B, F>(self, f: F) -> Map<Self, F> where Self: Sized, F: FnMut(Self::Item) -> B;
            fn for_each<F>(self, f: F) where Self: Sized, F: FnMut(Self::Item);
            fn filter<P>(self, predicate: P) -> Filter<Self, P> where Self: Sized, P: FnMut(&Self::Item) -> bool;
            fn filter_map<B, F>(self, f: F) -> FilterMap<Self, F> where Self: Sized, F: FnMut(Self::Item) -> Option<B>;
            fn enumerate(self) -> Enumerate<Self> where Self: Sized; fn peekable(self) -> Peekable<Self> where Self: Sized;
            fn skip_while<P>(self, predicate: P) -> SkipWhile<Self, P> where Self: Sized, P: FnMut(&Self::Item) -> bool;
            fn take_while<P>(self, predicate: P) -> TakeWhile<Self, P> where Self: Sized, P: FnMut(&Self::Item) -> bool;
            fn map_while<B, P>(self, predicate: P) -> MapWhile<Self, P> where Self: Sized, P: FnMut(Self::Item) -> Option<B>;
            fn skip(self, n: usize) -> Skip<Self> where Self: Sized; fn take(self, n: usize) -> Take<Self> where Self: Sized;
            fn scan<St, B, F>(self, initial_state: St, f: F) -> Scan<Self, St, F> where Self: Sized, F: FnMut(&mut St, Self::Item) -> Option<B>;
            fn flat_map<U, F>(self, f: F) -> FlatMap<Self, U, F> where Self: Sized, U: IntoIterator, F: FnMut(Self::Item) -> U;
            fn flatten(self) -> Flatten<Self> where Self: Sized, Self::Item: IntoIterator; fn fuse(self) -> Fuse<Self> where Self: Sized;
            fn inspect<F>(self, f: F) -> Inspect<Self, F> where Self: Sized, F: FnMut(&Self::Item); fn by_ref(&mut self) -> &mut Self where Self: Sized;
            fn collect<B: FromIterator<Self::Item>>(self) -> B where Self: Sized;
            fn partition<B, F>(self, f: F) -> (B, B) where Self: Sized, B: Default + Extend<Self::Item>, F: FnMut(&Self::Item) -> bool;
            fn try_fold<B, F, R>(&mut self, init: B, f: F) -> R where Self: Sized, F: FnMut(B, Self::Item) -> R;
            fn try_for_each<F, R>(&mut self, f: F) -> R where Self: Sized, F: FnMut(Self::Item) -> R;
            fn fold<B, F>(self, init: B, f: F) -> B where Self: Sized, F: FnMut(B, Self::Item) -> B;
            fn reduce<F>(self, f: F) -> Option<Self::Item> where Self: Sized, F: FnMut(Self::Item, Self::Item) -> Self::Item;
            fn all<F>(&mut self, f: F) -> bool where Self: Sized, F: FnMut(Self::Item) -> bool; fn any<F>(&mut self, f: F) -> bool where Self: Sized, F: FnMut(Self::Item) -> bool;
            fn find<P>(&mut self, predicate: P) -> Option<Self::Item> where Self: Sized, P: FnMut(&Self::Item) -> bool;
            fn find_map<B, F>(&mut self, f: F) -> Option<B> where Self: Sized, F: FnMut(Self::Item) -> Option<B>;
            fn position<P>(&mut self, predicate: P) -> Option<usize> where Self: Sized, P: FnMut(Self::Item) -> bool;
            fn rposition<P>(&mut self, predicate: P) -> Option<usize> where P: FnMut(Self::Item) -> bool, Self: Sized + ExactSizeIterator + DoubleEndedIterator;
            fn max(self) -> Option<Self::Item> where Self: Sized, Self::Item: Ord; fn min(self) -> Option<Self::Item> where Self: Sized, Self::Item: Ord;
            fn max_by_key<B: Ord, F>(self, f: F) -> Option<Self::Item> where Self: Sized, F: FnMut(&Self::Item) -> B;
            fn max_by<F>(self, compare: F) -> Option<Self::Item> where Self: Sized, F: FnMut(&Self::Item, &Self::Item) -> Ordering;
            fn min_by_key<B: Ord, F>(self, f: F) -> Option<Self::Item> where Self: Sized, F: FnMut(&Self::Item) -> B;
            fn min_by<F>(self, compare: F) -> Option<Self::Item> where Self: Sized, F: FnMut(&Self::Item, &Self::Item) -> Ordering;
            fn rev(self) -> Rev<Self> where Self: Sized + DoubleEndedIterator; fn unzip<A, B, FromA, FromB>(self) -> (FromA, FromB) where Self: Sized;
            fn copied<'a, T: 'a + Copy>(self) -> Copied<Self> where Self: Sized + Iterator<Item = &'a T>;
            fn cloned<'a, T: 'a + Clone>(self) -> Cloned<Self> where Self: Sized + Iterator<Item = &'a T>;
            fn cycle(self) -> Cycle<Self> where Self: Sized + Clone; fn sum<S>(self) -> S where Self: Sized, S: Sum<Self::Item>;
            fn product<P>(self) -> P where Self: Sized, P: Product<Self::Item>; fn eq<I>(self, other: I) -> bool where I: IntoIterator, Self: Sized;
            fn is_sorted(self) -> bool where Self: Sized; fn array_chunks<const N: usize>(self) -> ArrayChunks<Self, N> where Self: Sized;
        }
        pub trait IntoIterator { type Item; type IntoIter: Iterator<Item = Self::Item>; fn into_iter(self) -> Self::IntoIter; }
        impl<I: Iterator> IntoIterator for I { type Item = I::Item; type IntoIter = I; }
        pub trait FromIterator<A>: Sized { fn from_iter<T: IntoIterator<Item = A>>(iter: T) -> Self; }
        pub trait Extend<A> { fn extend<T: IntoIterator<Item = A>>(&mut self, iter: T); }
        pub trait DoubleEndedIterator: Iterator { fn next_back(&mut self) -> Option<Self::Item>; fn rfind<P>(&mut self, predicate: P) -> Option<Self::Item> where Self: Sized, P: FnMut(&Self::Item) -> bool; fn nth_back(&mut self, n: usize) -> Option<Self::Item>; }
        pub trait ExactSizeIterator: Iterator { fn len(&self) -> usize; fn is_empty(&self) -> bool; }
        pub trait FusedIterator: Iterator {}
        pub trait Sum<A = Self>: Sized { fn sum<I: Iterator<Item = A>>(iter: I) -> Self; }
        pub trait Product<A = Self>: Sized { fn product<I: Iterator<Item = A>>(iter: I) -> Self; }
        pub struct Map<I, F>; pub struct Filter<I, P>; pub struct FilterMap<I, F>; pub struct Enumerate<I>; pub struct Peekable<I: Iterator>;
        pub struct SkipWhile<I, P>; pub struct TakeWhile<I, P>; pub struct MapWhile<I, P>; pub struct Skip<I>; pub struct Take<I>; pub struct Scan<I, St, F>;
        pub struct FlatMap<I, U, F>; pub struct Flatten<I>; pub struct Fuse<I>; pub struct Inspect<I, F>; pub struct Rev<I>; pub struct Copied<I>; pub struct Cloned<I>;
        pub struct Cycle<I>; pub struct StepBy<I>; pub struct Chain<A, B>; pub struct Zip<A, B>; pub struct ArrayChunks<I, const N: usize>;
        impl<B, I: Iterator, F: FnMut(I::Item) -> B> Iterator for Map<I, F> { type Item = B; }
        impl<I: Iterator, P> Iterator for Filter<I, P> { type Item = I::Item; }
        impl<B, I: Iterator, F: FnMut(I::Item) -> Option<B>> Iterator for FilterMap<I, F> { type Item = B; }
        impl<I: Iterator> Iterator for Enumerate<I> { type Item = (usize, I::Item); }
        impl<I: Iterator> Iterator for Peekable<I> { type Item = I::Item; }
        impl<I: Iterator> Peekable<I> { pub fn peek(&mut self) -> Option<&I::Item>; pub fn peek_mut(&mut self) -> Option<&mut I::Item>; pub fn next_if(&mut self, func: impl FnOnce(&I::Item) -> bool) -> Option<I::Item>; }
        impl<I: Iterator, P> Iterator for SkipWhile<I, P> { type Item = I::Item; }
        impl<I: Iterator, P> Iterator for TakeWhile<I, P> { type Item = I::Item; }
        impl<I: Iterator> Iterator for Skip<I> { type Item = I::Item; }
        impl<I: Iterator> Iterator for Take<I> { type Item = I::Item; }
        impl<I: Iterator> Iterator for Fuse<I> { type Item = I::Item; }
        impl<I: Iterator, F> Iterator for Inspect<I, F> { type Item = I::Item; }
        impl<I: Iterator> Iterator for Rev<I> { type Item = I::Item; }
        impl<I: Iterator> Iterator for Cycle<I> { type Item = I::Item; }
        impl<I: Iterator> Iterator for StepBy<I> { type Item = I::Item; }
        impl<'a, I: Iterator<Item = &'a T>, T: Copy> Iterator for Copied<I> { type Item = T; }
        impl<'a, I: Iterator<Item = &'a T>, T: Clone> Iterator for Cloned<I> { type Item = T; }
        impl<A: Iterator, B> Iterator for Chain<A, B> { type Item = A::Item; }
        impl<A: Iterator, B: Iterator> Iterator for Zip<A, B> { type Item = (A::Item, B::Item); }
        impl<I: Iterator, U: IntoIterator, F> Iterator for FlatMap<I, U, F> { type Item = U::Item; }
        impl<I: Iterator<Item: IntoIterator>> Iterator for Flatten<I> { type Item = <I::Item as IntoIterator>::Item; }
        impl<I: DoubleEndedIterator> DoubleEndedIterator for Rev<I> {}
        impl<I: DoubleEndedIterator> DoubleEndedIterator for Enumerate<I> {}
        impl<I: ExactSizeIterator> ExactSizeIterator for Enumerate<I> {}
        pub fn empty<T>() -> Empty<T>; pub fn once<T>(value: T) -> Once<T>; pub fn repeat<T: Clone>(elt: T) -> Repeat<T>;
        pub fn from_fn<T, F: FnMut() -> Option<T>>(f: F) -> FromFn<F>; pub fn successors<T, F>(first: Option<T>, succ: F) -> Successors<T, F>; pub fn zip<A, B>(a: A, b: B) -> Zip<A::IntoIter, B::IntoIter>;
        mod repeat_with { pub fn repeat_with<A, F: FnMut() -> A>(repeater: F) -> RepeatWith<F>; }
        mod repeat_n { pub fn repeat_n<T: Clone>(element: T, count: usize) -> RepeatN<T>; }
        pub use repeat_with::*; pub use repeat_n::*;
        pub struct Empty<T>; pub struct Once<T>; pub struct Repeat<T>; pub struct RepeatWith<F>; pub struct RepeatN<T>; pub struct FromFn<F>; pub struct Successors<T, F>;
        impl<T> Iterator for Empty<T> { type Item = T; } impl<T> Iterator for Once<T> { type Item = T; } impl<T> Iterator for Repeat<T> { type Item = T; }
        impl<T> Iterator for RepeatN<T> { type Item = T; } impl<A, F: FnMut() -> A> Iterator for RepeatWith<F> { type Item = A; }
        impl<T, F: FnMut() -> Option<T>> Iterator for FromFn<F> { type Item = T; } impl<T, F> Iterator for Successors<T, F> { type Item = T; }
    }

    pub mod string {
        #[derive(Clone, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct String;
        impl String {
            pub fn new() -> String; pub fn with_capacity(capacity: usize) -> String; pub fn from_utf8(vec: Vec<u8>) -> Result<String, FromUtf8Error>;
            pub fn from_utf8_lossy(v: &[u8]) -> Cow<'_, str>; pub unsafe fn from_utf8_unchecked(bytes: Vec<u8>) -> String; pub fn from_utf16(v: &[u16]) -> Result<String, FromUtf16Error>;
            pub fn into_bytes(self) -> Vec<u8>; pub fn as_str(&self) -> &str; pub fn as_mut_str(&mut self) -> &mut str; pub fn push_str(&mut self, string: &str);
            pub fn capacity(&self) -> usize; pub fn reserve(&mut self, additional: usize); pub fn shrink_to_fit(&mut self); pub fn push(&mut self, ch: char);
            pub fn as_bytes(&self) -> &[u8]; pub fn truncate(&mut self, new_len: usize); pub fn pop(&mut self) -> Option<char>; pub fn remove(&mut self, idx: usize) -> char;
            pub fn retain<F: FnMut(char) -> bool>(&mut self, f: F); pub fn insert(&mut self, idx: usize, ch: char); pub fn insert_str(&mut self, idx: usize, string: &str);
            pub unsafe fn as_mut_vec(&mut self) -> &mut Vec<u8>; pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn split_off(&mut self, at: usize) -> String;
            pub fn clear(&mut self); pub fn drain<R>(&mut self, range: R) -> Drain<'_>; pub fn replace_range<R>(&mut self, range: R, replace_with: &str);
            pub fn into_boxed_str(self) -> Box<str>; pub fn leak<'a>(self) -> &'a mut str;
        }
        impl Deref for String { type Target = str; }
        impl DerefMut for String {}
        impl From<&str> for String {} impl From<char> for String {} impl From<Box<str>> for String {} impl From<Cow<'_, str>> for String {}
        impl FromStr for String { type Err = Infallible; }
        impl AsRef<str> for String {} impl AsRef<[u8]> for String {} impl AsRef<Path> for String {} impl AsRef<OsStr> for String {}
        impl Borrow<str> for String {}
        impl Extend<char> for String {} impl<'a> Extend<&'a str> for String {}
        impl FromIterator<char> for String {} impl FromIterator<String> for String {} impl<'a> FromIterator<&'a str> for String {}
        impl fmt::Write for String {}
        impl Add<&str> for String { type Output = String; }
        impl<I> Index<I> for String { type Output = str; }
        #[derive(Clone, Debug, Display, PartialEq, Eq)]
        pub struct FromUtf8Error;
        impl FromUtf8Error { pub fn into_bytes(self) -> Vec<u8>; pub fn utf8_error(&self) -> Utf8Error; pub fn as_bytes(&self) -> &[u8]; }
        #[derive(Debug, Display)] pub struct FromUtf16Error;
        pub struct Drain<'a>;
        impl<'a> Iterator for Drain<'a> { type Item = char; }
        pub trait ToString { fn to_string(&self) -> String; }
        impl<T: fmt::Display + ?Sized> ToString for T {}
    }

    pub mod str {
        mod converts {
            pub fn from_utf8(v: &[u8]) -> Result<&str, Utf8Error>;
            pub fn from_utf8_mut(v: &mut [u8]) -> Result<&mut str, Utf8Error>;
            pub unsafe fn from_utf8_unchecked(v: &[u8]) -> &str;
        }
        pub use converts::*;
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq)]
        pub struct Utf8Error;
        impl Utf8Error { pub fn valid_up_to(&self) -> usize; pub fn error_len(&self) -> Option<usize>; }
        pub trait FromStr: Sized { type Err; fn from_str(s: &str) -> Result<Self, Self::Err>; }
        pub use crate::primitive::{Chars, Bytes, Lines, Split, SplitWhitespace, CharIndices};
    }

    pub mod vec {
        #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Vec<T, A = Global>;
        impl<T> Vec<T> {
            pub const fn new() -> Vec<T>; pub fn with_capacity(capacity: usize) -> Vec<T>; pub unsafe fn from_raw_parts(ptr: *mut T, length: usize, capacity: usize) -> Vec<T>;
            pub fn capacity(&self) -> usize; pub fn reserve(&mut self, additional: usize); pub fn reserve_exact(&mut self, additional: usize);
            pub fn shrink_to_fit(&mut self); pub fn shrink_to(&mut self, min_capacity: usize); pub fn into_boxed_slice(self) -> Box<[T]>;
            pub fn truncate(&mut self, len: usize); pub fn as_slice(&self) -> &[T]; pub fn as_mut_slice(&mut self) -> &mut [T];
            pub fn as_ptr(&self) -> *const T; pub fn as_mut_ptr(&mut self) -> *mut T; pub unsafe fn set_len(&mut self, new_len: usize);
            pub fn swap_remove(&mut self, index: usize) -> T; pub fn insert(&mut self, index: usize, element: T); pub fn remove(&mut self, index: usize) -> T;
            pub fn retain<F: FnMut(&T) -> bool>(&mut self, f: F); pub fn retain_mut<F: FnMut(&mut T) -> bool>(&mut self, f: F);
            pub fn dedup_by_key<F, K>(&mut self, key: F) where F: FnMut(&mut T) -> K, K: PartialEq; pub fn dedup(&mut self) where T: PartialEq;
            pub fn push(&mut self, value: T); pub fn pop(&mut self) -> Option<T>; pub fn append(&mut self, other: &mut Vec<T>);
            pub fn drain<R>(&mut self, range: R) -> Drain<'_, T>; pub fn clear(&mut self); pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool;
            pub fn split_off(&mut self, at: usize) -> Vec<T>; pub fn resize(&mut self, new_len: usize, value: T) where T: Clone;
            pub fn resize_with<F: FnMut() -> T>(&mut self, new_len: usize, f: F); pub fn leak<'a>(self) -> &'a mut [T];
            pub fn spare_capacity_mut(&mut self) -> &mut [MaybeUninit<T>]; pub fn extend_from_slice(&mut self, other: &[T]) where T: Clone;
            pub fn splice<R, I: IntoIterator<Item = T>>(&mut self, range: R, replace_with: I) -> Splice<'_, I::IntoIter>;
            pub fn extract_if<F>(&mut self, filter: F) -> Drain<'_, T>; pub fn pop_if(&mut self, predicate: impl FnOnce(&mut T) -> bool) -> Option<T>;
        }
        impl<T> Deref for Vec<T> { type Target = [T]; }
        impl<T> DerefMut for Vec<T> {}
        impl<T> IntoIterator for Vec<T> { type Item = T; type IntoIter = IntoIter<T>; }
        impl<'a, T> IntoIterator for &'a Vec<T> { type Item = &'a T; type IntoIter = Iter<'a, T>; }
        impl<'a, T> IntoIterator for &'a mut Vec<T> { type Item = &'a mut T; type IntoIter = IterMut<'a, T>; }
        impl<T> Extend<T> for Vec<T> {} impl<'a, T: Copy> Extend<&'a T> for Vec<T> {}
        impl<T> FromIterator<T> for Vec<T> {}
        impl<T> AsRef<[T]> for Vec<T> {} impl<T> AsMut<[T]> for Vec<T> {}
        impl<T, I> Index<I> for Vec<T> { type Output = T; }
        impl<T> From<&[T]> for Vec<T> {} impl From<&str> for Vec<u8> {} impl From<String> for Vec<u8> {} impl<T, const N: usize> From<[T; N]> for Vec<T> {}
        impl io::Write for Vec<u8> {}
        pub struct IntoIter<T>; pub struct Drain<'a, T>; pub struct Splice<'a, I>;
        impl<T> Iterator for IntoIter<T> { type Item = T; }
        impl<T> DoubleEndedIterator for IntoIter<T> {}
        impl<'a, T> Iterator for Drain<'a, T> { type Item = T; }
        impl<'a, I: Iterator> Iterator for Splice<'a, I> { type Item = I::Item; }
    }

    pub mod boxed {
        #[derive(Clone, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Box<T: ?Sized, A = Global>;
        impl<T> Box<T> {
            pub fn new(x: T) -> Box<T>; pub fn pin(x: T) -> Pin<Box<T>>; pub fn new_uninit() -> Box<MaybeUninit<T>>;
        }
        impl<T: ?Sized> Box<T> {
            pub unsafe fn from_raw(raw: *mut T) -> Box<T>; pub fn into_raw(b: Box<T>) -> *mut T; pub fn leak<'a>(b: Box<T>) -> &'a mut T;
            pub fn into_pin(boxed: Box<T>) -> Pin<Box<T>>; pub fn as_ptr(b: &Box<T>) -> *const T; pub fn as_mut_ptr(b: &mut Box<T>) -> *mut T;
        }
        impl<T: ?Sized> Deref for Box<T> { type Target = T; }
        impl<T: ?Sized> DerefMut for Box<T> {}
        impl<T> From<T> for Box<T> {}
        impl<I: Iterator + ?Sized> Iterator for Box<I> { type Item = I::Item; }
        impl<F: Future + ?Sized> Future for Box<F> { type Output = F::Output; }
    }

    pub mod rc {
        #[derive(Clone, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Rc<T: ?Sized>;
        impl<T> Rc<T> { pub fn new(value: T) -> Rc<T>; pub fn pin(value: T) -> Pin<Rc<T>>; pub fn try_unwrap(this: Self) -> Result<T, Self>; pub fn into_inner(this: Self) -> Option<T>; }
        impl<T: ?Sized> Rc<T> {
            pub fn strong_count(this: &Self) -> usize; pub fn weak_count(this: &Self) -> usize; pub fn downgrade(this: &Self) -> Weak<T>;
            pub fn ptr_eq(this: &Self, other: &Self) -> bool; pub fn get_mut(this: &mut Self) -> Option<&mut T>; pub fn as_ptr(this: &Self) -> *const T;
            pub fn into_raw(this: Self) -> *const T; pub unsafe fn from_raw(ptr: *const T) -> Self; pub fn make_mut(this: &mut Self) -> &mut T where T: Clone;
        }
        impl<T: ?Sized> Deref for Rc<T> { type Target = T; }
        #[derive(Clone, Debug)] pub struct Weak<T: ?Sized>;
        impl<T> Weak<T> { pub const fn new() -> Weak<T>; }
        impl<T: ?Sized> Weak<T> { pub fn upgrade(&self) -> Option<Rc<T>>; pub fn strong_count(&self) -> usize; }
    }

    pub mod sync {
        #[derive(Clone, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Arc<T: ?Sized>;
        impl<T> Arc<T> { pub fn new(data: T) -> Arc<T>; pub fn pin(data: T) -> Pin<Arc<T>>; pub fn try_unwrap(this: Self) -> Result<T, Self>; pub fn into_inner(this: Self) -> Option<T>; pub fn new_cyclic<F>(data_fn: F) -> Arc<T>; }
        impl<T: ?Sized> Arc<T> {
            pub fn strong_count(this: &Self) -> usize; pub fn weak_count(this: &Self) -> usize; pub fn downgrade(this: &Self) -> Weak<T>;
            pub fn ptr_eq(this: &Self, other: &Self) -> bool; pub fn get_mut(this: &mut Self) -> Option<&mut T>; pub fn as_ptr(this: &Self) -> *const T;
            pub fn into_raw(this: Self) -> *const T; pub unsafe fn from_raw(ptr: *const T) -> Self; pub fn make_mut(this: &mut Self) -> &mut T where T: Clone;
            pub unsafe fn increment_strong_count(ptr: *const T); pub unsafe fn decrement_strong_count(ptr: *const T);
        }
        impl<T: ?Sized> Deref for Arc<T> { type Target = T; }
        impl<T> From<T> for Arc<T> {}
        #[derive(Clone, Debug)] pub struct Weak<T: ?Sized>;
        impl<T> Weak<T> { pub const fn new() -> Weak<T>; }
        impl<T: ?Sized> Weak<T> { pub fn upgrade(&self) -> Option<Arc<T>>; pub fn strong_count(&self) -> usize; pub fn ptr_eq(&self, other: &Self) -> bool; }

        #[derive(Debug, Default)]
        pub struct Mutex<T: ?Sized>;
        impl<T> Mutex<T> { pub const fn new(t: T) -> Mutex<T>; pub fn into_inner(self) -> LockResult<T>; }
        impl<T: ?Sized> Mutex<T> {
            pub fn lock(&self) -> LockResult<MutexGuard<'_, T>>; pub fn try_lock(&self) -> TryLockResult<MutexGuard<'_, T>>;
            pub fn is_poisoned(&self) -> bool; pub fn clear_poison(&self); pub fn get_mut(&mut self) -> LockResult<&mut T>;
        }
        #[derive(Debug, Display)] pub struct MutexGuard<'a, T: ?Sized>;
        impl<'a, T: ?Sized> Deref for MutexGuard<'a, T> { type Target = T; }
        impl<'a, T: ?Sized> DerefMut for MutexGuard<'a, T> {}
        #[derive(Debug, Default)]
        pub struct RwLock<T: ?Sized>;
        impl<T> RwLock<T> { pub const fn new(t: T) -> RwLock<T>; pub fn into_inner(self) -> LockResult<T>; }
        impl<T: ?Sized> RwLock<T> {
            pub fn read(&self) -> LockResult<RwLockReadGuard<'_, T>>; pub fn write(&self) -> LockResult<RwLockWriteGuard<'_, T>>;
            pub fn try_read(&self) -> TryLockResult<RwLockReadGuard<'_, T>>; pub fn try_write(&self) -> TryLockResult<RwLockWriteGuard<'_, T>>;
            pub fn get_mut(&mut self) -> LockResult<&mut T>; pub fn is_poisoned(&self) -> bool;
        }
        #[derive(Debug, Display)] pub struct RwLockReadGuard<'a, T: ?Sized>;
        #[derive(Debug, Display)] pub struct RwLockWriteGuard<'a, T: ?Sized>;
        impl<'a, T: ?Sized> Deref for RwLockReadGuard<'a, T> { type Target = T; }
        impl<'a, T: ?Sized> Deref for RwLockWriteGuard<'a, T> { type Target = T; }
        impl<'a, T: ?Sized> DerefMut for RwLockWriteGuard<'a, T> {}
        #[derive(Debug, Display)] pub struct PoisonError<T>;
        impl<T> PoisonError<T> { pub fn new(guard: T) -> PoisonError<T>; pub fn into_inner(self) -> T; pub fn get_ref(&self) -> &T; pub fn get_mut(&mut self) -> &mut T; }
        #[derive(Debug, Display)] pub enum TryLockError<T> { Poisoned(PoisonError<T>), WouldBlock }
        pub type LockResult<Guard> = Result<Guard, PoisonError<Guard>>;
        pub type TryLockResult<Guard> = Result<Guard, TryLockError<Guard>>;
        #[derive(Debug, Default)] pub struct Condvar;
        impl Condvar {
            pub const fn new() -> Condvar; pub fn wait<'a, T>(&self, guard: MutexGuard<'a, T>) -> LockResult<MutexGuard<'a, T>>;
            pub fn wait_while<'a, T, F>(&self, guard: MutexGuard<'a, T>, condition: F) -> LockResult<MutexGuard<'a, T>> where F: FnMut(&mut T) -> bool;
            pub fn wait_timeout<'a, T>(&self, guard: MutexGuard<'a, T>, dur: Duration) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)>;
            pub fn wait_timeout_while<'a, T, F>(&self, guard: MutexGuard<'a, T>, dur: Duration, condition: F) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)>;
            pub fn notify_one(&self); pub fn notify_all(&self);
        }
        #[derive(Clone, Copy, Debug, PartialEq, Eq)] pub struct WaitTimeoutResult;
        impl WaitTimeoutResult { pub fn timed_out(&self) -> bool; }
        #[derive(Debug, Default)] pub struct OnceLock<T>;
        impl<T> OnceLock<T> {
            pub const fn new() -> OnceLock<T>; pub fn get(&self) -> Option<&T>; pub fn get_mut(&mut self) -> Option<&mut T>; pub fn set(&self, value: T) -> Result<(), T>;
            pub fn get_or_init<F: FnOnce() -> T>(&self, f: F) -> &T; pub fn into_inner(self) -> Option<T>; pub fn take(&mut self) -> Option<T>;
        }
        pub struct LazyLock<T, F = fn() -> T>;
        impl<T, F: FnOnce() -> T> LazyLock<T, F> { pub const fn new(f: F) -> LazyLock<T, F>; pub fn force(this: &LazyLock<T, F>) -> &T; }
        impl<T, F: FnOnce() -> T> Deref for LazyLock<T, F> { type Target = T; }
        pub struct Once;
        impl Once { pub const fn new() -> Once; pub fn call_once<F: FnOnce()>(&self, f: F); pub fn is_completed(&self) -> bool; }
        pub struct Barrier;
        impl Barrier { pub const fn new(n: usize) -> Barrier; pub fn wait(&self) -> BarrierWaitResult; }
        pub struct BarrierWaitResult;

        pub mod atomic {
            #[derive(Debug, Default)]
            pub struct Atomic<T>;
            impl<T> Atomic<T> {
                pub const fn new(v: T) -> Self; pub fn load(&self, order: Ordering) -> T; pub fn store(&self, val: T, order: Ordering);
                pub fn swap(&self, val: T, order: Ordering) -> T; pub fn get_mut(&mut self) -> &mut T; pub fn into_inner(self) -> T; pub fn as_ptr(&self) -> *mut T;
                pub fn compare_exchange(&self, current: T, new: T, success: Ordering, failure: Ordering) -> Result<T, T>;
                pub fn compare_exchange_weak(&self, current: T, new: T, success: Ordering, failure: Ordering) -> Result<T, T>;
                pub fn fetch_add(&self, val: T, order: Ordering) -> T; pub fn fetch_sub(&self, val: T, order: Ordering) -> T;
                pub fn fetch_or(&self, val: T, order: Ordering) -> T; pub fn fetch_and(&self, val: T, order: Ordering) -> T; pub fn fetch_xor(&self, val: T, order: Ordering) -> T;
                pub fn fetch_nand(&self, val: T, order: Ordering) -> T; pub fn fetch_max(&self, val: T, order: Ordering) -> T; pub fn fetch_min(&self, val: T, order: Ordering) -> T;
                pub fn fetch_update<F>(&self, set_order: Ordering, fetch_order: Ordering, f: F) -> Result<T, T> where F: FnMut(T) -> Option<T>;
                pub fn fetch_not(&self, order: Ordering) -> T;
            }
            pub type AtomicBool = Atomic<bool>;
            pub type AtomicU8 = Atomic<u8>; pub type AtomicU16 = Atomic<u16>; pub type AtomicU32 = Atomic<u32>; pub type AtomicU64 = Atomic<u64>; pub type AtomicUsize = Atomic<usize>;
            pub type AtomicI8 = Atomic<i8>; pub type AtomicI16 = Atomic<i16>; pub type AtomicI32 = Atomic<i32>; pub type AtomicI64 = Atomic<i64>; pub type AtomicIsize = Atomic<isize>;
            pub type AtomicPtr<T> = Atomic<*mut T>;
            #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
            pub enum Ordering { Relaxed, Release, Acquire, AcqRel, SeqCst }
            pub fn fence(order: Ordering); pub fn compiler_fence(order: Ordering); pub fn spin_loop_hint();
        }

        pub mod mpsc {
            pub fn channel<T>() -> (Sender<T>, Receiver<T>);
            pub fn sync_channel<T>(bound: usize) -> (SyncSender<T>, Receiver<T>);
            #[derive(Clone, Debug)] pub struct Sender<T>;
            impl<T> Sender<T> { pub fn send(&self, t: T) -> Result<(), SendError<T>>; }
            #[derive(Clone, Debug)] pub struct SyncSender<T>;
            impl<T> SyncSender<T> { pub fn send(&self, t: T) -> Result<(), SendError<T>>; pub fn try_send(&self, t: T) -> Result<(), TrySendError<T>>; }
            #[derive(Debug)] pub struct Receiver<T>;
            impl<T> Receiver<T> {
                pub fn recv(&self) -> Result<T, RecvError>; pub fn try_recv(&self) -> Result<T, TryRecvError>; pub fn recv_timeout(&self, timeout: Duration) -> Result<T, RecvTimeoutError>;
                pub fn iter(&self) -> Iter<'_, T>; pub fn try_iter(&self) -> TryIter<'_, T>;
            }
            pub struct Iter<'a, T>; pub struct TryIter<'a, T>;
            impl<'a, T> Iterator for Iter<'a, T> { type Item = T; }
            impl<'a, T> Iterator for TryIter<'a, T> { type Item = T; }
            #[derive(Debug, Display, Clone, Copy, PartialEq, Eq)] pub struct SendError<T>(pub T);
            #[derive(Debug, Display, Clone, Copy, PartialEq, Eq)] pub struct RecvError;
            #[derive(Debug, Display, Clone, Copy, PartialEq, Eq)] pub enum TryRecvError { Empty, Disconnected }
            #[derive(Debug, Display, Clone, Copy, PartialEq, Eq)] pub enum RecvTimeoutError { Timeout, Disconnected }
            #[derive(Debug, Display, Clone, Copy, PartialEq, Eq)] pub enum TrySendError<T> { Full(T), Disconnected(T) }
        }
    }

    pub mod cell {
        #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
        pub struct Cell<T: ?Sized>;
        impl<T> Cell<T> {
            pub const fn new(value: T) -> Cell<T>; pub fn set(&self, val: T); pub fn replace(&self, val: T) -> T; pub fn into_inner(self) -> T;
            pub fn get(&self) -> T where T: Copy; pub fn take(&self) -> T where T: Default; pub fn swap(&self, other: &Self);
        }
        impl<T: ?Sized> Cell<T> { pub fn get_mut(&mut self) -> &mut T; pub fn as_ptr(&self) -> *mut T; }
        #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
        pub struct RefCell<T: ?Sized>;
        impl<T> RefCell<T> { pub const fn new(value: T) -> RefCell<T>; pub fn into_inner(self) -> T; pub fn replace(&self, t: T) -> T; pub fn take(&self) -> T where T: Default; }
        impl<T: ?Sized> RefCell<T> {
            pub fn borrow(&self) -> Ref<'_, T>; pub fn borrow_mut(&self) -> RefMut<'_, T>; pub fn try_borrow(&self) -> Result<Ref<'_, T>, BorrowError>;
            pub fn try_borrow_mut(&self) -> Result<RefMut<'_, T>, BorrowMutError>; pub fn get_mut(&mut self) -> &mut T; pub fn as_ptr(&self) -> *mut T;
        }
        #[derive(Debug, Display)] pub struct Ref<'b, T: ?Sized>;
        #[derive(Debug, Display)] pub struct RefMut<'b, T: ?Sized>;
        impl<'b, T: ?Sized> Deref for Ref<'b, T> { type Target = T; }
        impl<'b, T: ?Sized> Deref for RefMut<'b, T> { type Target = T; }
        impl<'b, T: ?Sized> DerefMut for RefMut<'b, T> {}
        impl<'b, T: ?Sized> Ref<'b, T> { pub fn map<U: ?Sized, F>(orig: Ref<'b, T>, f: F) -> Ref<'b, U> where F: FnOnce(&T) -> &U; }
        impl<'b, T: ?Sized> RefMut<'b, T> { pub fn map<U: ?Sized, F>(orig: RefMut<'b, T>, f: F) -> RefMut<'b, U> where F: FnOnce(&mut T) -> &mut U; }
        #[derive(Debug, Display)] pub struct BorrowError;
        #[derive(Debug, Display)] pub struct BorrowMutError;
        #[derive(Debug, Default)]
        pub struct UnsafeCell<T: ?Sized>;
        impl<T> UnsafeCell<T> { pub const fn new(value: T) -> UnsafeCell<T>; pub fn into_inner(self) -> T; }
        impl<T: ?Sized> UnsafeCell<T> { pub const fn get(&self) -> *mut T; pub fn get_mut(&mut self) -> &mut T; pub const fn raw_get(this: *const Self) -> *mut T; }
        #[derive(Clone, Debug, Default)]
        pub struct OnceCell<T>;
        impl<T> OnceCell<T> { pub const fn new() -> OnceCell<T>; pub fn get(&self) -> Option<&T>; pub fn set(&self, value: T) -> Result<(), T>; pub fn get_or_init<F: FnOnce() -> T>(&self, f: F) -> &T; pub fn take(&mut self) -> Option<T>; }
        pub struct LazyCell<T, F = fn() -> T>;
        impl<T, F: FnOnce() -> T> Deref for LazyCell<T, F> { type Target = T; }
    }

    pub mod collections {
        pub mod hash_map {
            #[derive(Clone, Debug, Default, PartialEq, Eq)]
            pub struct HashMap<K, V, S = RandomState>;
            impl<K, V> HashMap<K, V> { pub fn new() -> HashMap<K, V>; pub fn with_capacity(capacity: usize) -> HashMap<K, V>; }
            impl<K, V, S> HashMap<K, V, S> {
                pub fn with_hasher(hash_builder: S) -> HashMap<K, V, S>; pub fn with_capacity_and_hasher(capacity: usize, hasher: S) -> HashMap<K, V, S>;
                pub fn capacity(&self) -> usize; pub fn keys(&self) -> Keys<'_, K, V>; pub fn into_keys(self) -> IntoKeys<K, V>; pub fn values(&self) -> Values<'_, K, V>;
                pub fn values_mut(&mut self) -> ValuesMut<'_, K, V>; pub fn into_values(self) -> IntoValues<K, V>; pub fn iter(&self) -> Iter<'_, K, V>;
                pub fn iter_mut(&mut self) -> IterMut<'_, K, V>; pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn drain(&mut self) -> Drain<'_, K, V>;
                pub fn retain<F>(&mut self, f: F) where F: FnMut(&K, &mut V) -> bool; pub fn clear(&mut self); pub fn hasher(&self) -> &S;
                pub fn reserve(&mut self, additional: usize); pub fn shrink_to_fit(&mut self); pub fn entry(&mut self, key: K) -> Entry<'_, K, V>;
                pub fn get<Q: ?Sized>(&self, k: &Q) -> Option<&V>; pub fn get_key_value<Q: ?Sized>(&self, k: &Q) -> Option<(&K, &V)>;
                pub fn contains_key<Q: ?Sized>(&self, k: &Q) -> bool; pub fn get_mut<Q: ?Sized>(&mut self, k: &Q) -> Option<&mut V>;
                pub fn insert(&mut self, k: K, v: V) -> Option<V>; pub fn remove<Q: ?Sized>(&mut self, k: &Q) -> Option<V>;
                pub fn remove_entry<Q: ?Sized>(&mut self, k: &Q) -> Option<(K, V)>; pub fn extract_if<F>(&mut self, pred: F) -> Drain<'_, K, V>;
            }
            impl<K, V, S> IntoIterator for HashMap<K, V, S> { type Item = (K, V); type IntoIter = IntoIter<K, V>; }
            impl<'a, K, V, S> IntoIterator for &'a HashMap<K, V, S> { type Item = (&'a K, &'a V); type IntoIter = Iter<'a, K, V>; }
            impl<'a, K, V, S> IntoIterator for &'a mut HashMap<K, V, S> { type Item = (&'a K, &'a mut V); type IntoIter = IterMut<'a, K, V>; }
            impl<K, V, S> Extend<(K, V)> for HashMap<K, V, S> {} impl<K, V, S> FromIterator<(K, V)> for HashMap<K, V, S> {}
            impl<K, Q: ?Sized, V, S> Index<&Q> for HashMap<K, V, S> { type Output = V; }
            pub struct Iter<'a, K, V>; pub struct IterMut<'a, K, V>; pub struct IntoIter<K, V>; pub struct Keys<'a, K, V>; pub struct Values<'a, K, V>;
            pub struct ValuesMut<'a, K, V>; pub struct IntoKeys<K, V>; pub struct IntoValues<K, V>; pub struct Drain<'a, K, V>;
            impl<'a, K, V> Iterator for Iter<'a, K, V> { type Item = (&'a K, &'a V); }
            impl<'a, K, V> Iterator for IterMut<'a, K, V> { type Item = (&'a K, &'a mut V); }
            impl<K, V> Iterator for IntoIter<K, V> { type Item = (K, V); }
            impl<'a, K, V> Iterator for Keys<'a, K, V> { type Item = &'a K; }
            impl<'a, K, V> Iterator for Values<'a, K, V> { type Item = &'a V; }
            impl<'a, K, V> Iterator for ValuesMut<'a, K, V> { type Item = &'a mut V; }
            impl<K, V> Iterator for IntoKeys<K, V> { type Item = K; }
            impl<K, V> Iterator for IntoValues<K, V> { type Item = V; }
            impl<'a, K, V> Iterator for Drain<'a, K, V> { type Item = (K, V); }
            pub enum Entry<'a, K, V> { Occupied(OccupiedEntry<'a, K, V>), Vacant(VacantEntry<'a, K, V>) }
            impl<'a, K, V> Entry<'a, K, V> {
                pub fn or_insert(self, default: V) -> &'a mut V; pub fn or_insert_with<F: FnOnce() -> V>(self, default: F) -> &'a mut V;
                pub fn or_insert_with_key<F: FnOnce(&K) -> V>(self, default: F) -> &'a mut V; pub fn key(&self) -> &K;
                pub fn and_modify<F: FnOnce(&mut V)>(self, f: F) -> Self; pub fn or_default(self) -> &'a mut V where V: Default;
                pub fn insert_entry(self, value: V) -> OccupiedEntry<'a, K, V>;
            }
            pub struct OccupiedEntry<'a, K, V>; pub struct VacantEntry<'a, K, V>;
            impl<'a, K, V> OccupiedEntry<'a, K, V> {
                pub fn key(&self) -> &K; pub fn get(&self) -> &V; pub fn get_mut(&mut self) -> &mut V; pub fn into_mut(self) -> &'a mut V;
                pub fn insert(&mut self, value: V) -> V; pub fn remove(self) -> V; pub fn remove_entry(self) -> (K, V);
            }
            impl<'a, K, V> VacantEntry<'a, K, V> { pub fn key(&self) -> &K; pub fn into_key(self) -> K; pub fn insert(self, value: V) -> &'a mut V; }
            #[derive(Clone, Debug, Default)] pub struct RandomState;
            impl RandomState { pub fn new() -> RandomState; }
            impl BuildHasher for RandomState { type Hasher = DefaultHasher; }
            #[derive(Clone, Debug, Default)] pub struct DefaultHasher;
            impl DefaultHasher { pub fn new() -> DefaultHasher; }
            impl Hasher for DefaultHasher {}
        }
        pub mod hash_set {
            #[derive(Clone, Debug, Default, PartialEq, Eq)]
            pub struct HashSet<T, S = RandomState>;
            impl<T> HashSet<T> { pub fn new() -> HashSet<T>; pub fn with_capacity(capacity: usize) -> HashSet<T>; }
            impl<T, S> HashSet<T, S> {
                pub fn capacity(&self) -> usize; pub fn iter(&self) -> Iter<'_, T>; pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool;
                pub fn drain(&mut self) -> Drain<'_, T>; pub fn retain<F>(&mut self, f: F) where F: FnMut(&T) -> bool; pub fn clear(&mut self);
                pub fn with_hasher(hasher: S) -> HashSet<T, S>; pub fn reserve(&mut self, additional: usize);
                pub fn difference<'a>(&'a self, other: &'a HashSet<T, S>) -> Iter<'a, T>; pub fn union<'a>(&'a self, other: &'a HashSet<T, S>) -> Iter<'a, T>;
                pub fn intersection<'a>(&'a self, other: &'a HashSet<T, S>) -> Iter<'a, T>; pub fn contains<Q: ?Sized>(&self, value: &Q) -> bool;
                pub fn get<Q: ?Sized>(&self, value: &Q) -> Option<&T>; pub fn is_subset(&self, other: &HashSet<T, S>) -> bool;
                pub fn insert(&mut self, value: T) -> bool; pub fn replace(&mut self, value: T) -> Option<T>; pub fn remove<Q: ?Sized>(&mut self, value: &Q) -> bool;
                pub fn take<Q: ?Sized>(&mut self, value: &Q) -> Option<T>;
            }
            impl<T, S> IntoIterator for HashSet<T, S> { type Item = T; type IntoIter = IntoIter<T>; }
            impl<'a, T, S> IntoIterator for &'a HashSet<T, S> { type Item = &'a T; type IntoIter = Iter<'a, T>; }
            impl<T, S> Extend<T> for HashSet<T, S> {} impl<T, S> FromIterator<T> for HashSet<T, S> {}
            pub struct Iter<'a, K>; pub struct IntoIter<K>; pub struct Drain<'a, K>;
            impl<'a, K> Iterator for Iter<'a, K> { type Item = &'a K; }
            impl<K> Iterator for IntoIter<K> { type Item = K; }
            impl<'a, K> Iterator for Drain<'a, K> { type Item = K; }
        }
        pub mod btree_map {
            #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
            pub struct BTreeMap<K, V>;
            impl<K, V> BTreeMap<K, V> {
                pub const fn new() -> BTreeMap<K, V>; pub fn clear(&mut self); pub fn get<Q: ?Sized>(&self, key: &Q) -> Option<&V>;
                pub fn get_key_value<Q: ?Sized>(&self, k: &Q) -> Option<(&K, &V)>; pub fn first_key_value(&self) -> Option<(&K, &V)>; pub fn last_key_value(&self) -> Option<(&K, &V)>;
                pub fn pop_first(&mut self) -> Option<(K, V)>; pub fn pop_last(&mut self) -> Option<(K, V)>; pub fn contains_key<Q: ?Sized>(&self, key: &Q) -> bool;
                pub fn get_mut<Q: ?Sized>(&mut self, key: &Q) -> Option<&mut V>; pub fn insert(&mut self, key: K, value: V) -> Option<V>;
                pub fn remove<Q: ?Sized>(&mut self, key: &Q) -> Option<V>; pub fn retain<F>(&mut self, f: F) where F: FnMut(&K, &mut V) -> bool;
                pub fn append(&mut self, other: &mut Self); pub fn range<T: ?Sized, R>(&self, range: R) -> Range<'_, K, V>; pub fn entry(&mut self, key: K) -> Entry<'_, K, V>;
                pub fn split_off<Q: ?Sized>(&mut self, key: &Q) -> Self; pub fn iter(&self) -> Iter<'_, K, V>; pub fn iter_mut(&mut self) -> IterMut<'_, K, V>;
                pub fn keys(&self) -> Keys<'_, K, V>; pub fn values(&self) -> Values<'_, K, V>; pub fn values_mut(&mut self) -> ValuesMut<'_, K, V>;
                pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn into_keys(self) -> IntoKeys<K, V>; pub fn into_values(self) -> IntoValues<K, V>;
            }
            impl<K, V> IntoIterator for BTreeMap<K, V> { type Item = (K, V); type IntoIter = IntoIter<K, V>; }
            impl<'a, K, V> IntoIterator for &'a BTreeMap<K, V> { type Item = (&'a K, &'a V); type IntoIter = Iter<'a, K, V>; }
            impl<K, V> Extend<(K, V)> for BTreeMap<K, V> {} impl<K, V> FromIterator<(K, V)> for BTreeMap<K, V> {}
            pub struct Iter<'a, K, V>; pub struct IterMut<'a, K, V>; pub struct IntoIter<K, V>; pub struct Keys<'a, K, V>; pub struct Values<'a, K, V>;
            pub struct ValuesMut<'a, K, V>; pub struct IntoKeys<K, V>; pub struct IntoValues<K, V>; pub struct Range<'a, K, V>;
            impl<'a, K, V> Iterator for Iter<'a, K, V> { type Item = (&'a K, &'a V); }
            impl<'a, K, V> Iterator for IterMut<'a, K, V> { type Item = (&'a K, &'a mut V); }
            impl<K, V> Iterator for IntoIter<K, V> { type Item = (K, V); }
            impl<'a, K, V> Iterator for Keys<'a, K, V> { type Item = &'a K; }
            impl<'a, K, V> Iterator for Values<'a, K, V> { type Item = &'a V; }
            impl<'a, K, V> Iterator for ValuesMut<'a, K, V> { type Item = &'a mut V; }
            impl<K, V> Iterator for IntoKeys<K, V> { type Item = K; }
            impl<K, V> Iterator for IntoValues<K, V> { type Item = V; }
            impl<'a, K, V> Iterator for Range<'a, K, V> { type Item = (&'a K, &'a V); }
            impl<'a, K, V> DoubleEndedIterator for Iter<'a, K, V> {} impl<'a, K, V> DoubleEndedIterator for Range<'a, K, V> {}
            pub enum Entry<'a, K, V> { Vacant(VacantEntry<'a, K, V>), Occupied(OccupiedEntry<'a, K, V>) }
            impl<'a, K, V> Entry<'a, K, V> {
                pub fn or_insert(self, default: V) -> &'a mut V; pub fn or_insert_with<F: FnOnce() -> V>(self, default: F) -> &'a mut V;
                pub fn or_default(self) -> &'a mut V where V: Default; pub fn and_modify<F: FnOnce(&mut V)>(self, f: F) -> Self; pub fn key(&self) -> &K;
            }
            pub struct OccupiedEntry<'a, K, V>; pub struct VacantEntry<'a, K, V>;
        }
        pub mod btree_set {
            #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
            pub struct BTreeSet<T>;
            impl<T> BTreeSet<T> {
                pub const fn new() -> BTreeSet<T>; pub fn contains<Q: ?Sized>(&self, value: &Q) -> bool; pub fn insert(&mut self, value: T) -> bool;
                pub fn remove<Q: ?Sized>(&mut self, value: &Q) -> bool; pub fn iter(&self) -> Iter<'_, T>; pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool;
                pub fn first(&self) -> Option<&T>; pub fn last(&self) -> Option<&T>; pub fn pop_first(&mut self) -> Option<T>; pub fn pop_last(&mut self) -> Option<T>;
                pub fn clear(&mut self); pub fn retain<F>(&mut self, f: F) where F: FnMut(&T) -> bool; pub fn range<K: ?Sized, R>(&self, range: R) -> Iter<'_, T>;
                pub fn difference<'a>(&'a self, other: &'a BTreeSet<T>) -> Iter<'a, T>; pub fn union<'a>(&'a self, other: &'a BTreeSet<T>) -> Iter<'a, T>;
            }
            impl<T> IntoIterator for BTreeSet<T> { type Item = T; type IntoIter = IntoIter<T>; }
            impl<'a, T> IntoIterator for &'a BTreeSet<T> { type Item = &'a T; type IntoIter = Iter<'a, T>; }
            impl<T> Extend<T> for BTreeSet<T> {} impl<T> FromIterator<T> for BTreeSet<T> {}
            pub struct Iter<'a, T>; pub struct IntoIter<T>;
            impl<'a, T> Iterator for Iter<'a, T> { type Item = &'a T; }
            impl<T> Iterator for IntoIter<T> { type Item = T; }
        }
        pub mod vec_deque {
            #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
            pub struct VecDeque<T>;
            impl<T> VecDeque<T> {
                pub const fn new() -> VecDeque<T>; pub fn with_capacity(capacity: usize) -> VecDeque<T>; pub fn get(&self, index: usize) -> Option<&T>;
                pub fn get_mut(&mut self, index: usize) -> Option<&mut T>; pub fn swap(&mut self, i: usize, j: usize); pub fn capacity(&self) -> usize;
                pub fn reserve(&mut self, additional: usize); pub fn truncate(&mut self, len: usize); pub fn iter(&self) -> Iter<'_, T>; pub fn iter_mut(&mut self) -> IterMut<'_, T>;
                pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn range<R>(&self, range: R) -> Iter<'_, T>; pub fn drain<R>(&mut self, range: R) -> Drain<'_, T>;
                pub fn clear(&mut self); pub fn contains(&self, x: &T) -> bool where T: PartialEq; pub fn front(&self) -> Option<&T>; pub fn front_mut(&mut self) -> Option<&mut T>;
                pub fn back(&self) -> Option<&T>; pub fn back_mut(&mut self) -> Option<&mut T>; pub fn pop_front(&mut self) -> Option<T>; pub fn pop_back(&mut self) -> Option<T>;
                pub fn push_front(&mut self, value: T); pub fn push_back(&mut self, value: T); pub fn insert(&mut self, index: usize, value: T); pub fn remove(&mut self, index: usize) -> Option<T>;
                pub fn append(&mut self, other: &mut Self); pub fn retain<F>(&mut self, f: F) where F: FnMut(&T) -> bool; pub fn make_contiguous(&mut self) -> &mut [T];
                pub fn as_slices(&self) -> (&[T], &[T]); pub fn split_off(&mut self, at: usize) -> Self; pub fn resize(&mut self, new_len: usize, value: T) where T: Clone;
                pub fn swap_remove_back(&mut self, index: usize) -> Option<T>; pub fn pop_front_if(&mut self, predicate: impl FnOnce(&mut T) -> bool) -> Option<T>;
            }
            impl<T> IntoIterator for VecDeque<T> { type Item = T; type IntoIter = IntoIter<T>; }
            impl<'a, T> IntoIterator for &'a VecDeque<T> { type Item = &'a T; type IntoIter = Iter<'a, T>; }
            impl<T> Extend<T> for VecDeque<T> {} impl<T> FromIterator<T> for VecDeque<T> {}
            impl<T> Index<usize> for VecDeque<T> { type Output = T; }
            pub struct Iter<'a, T>; pub struct IterMut<'a, T>; pub struct IntoIter<T>; pub struct Drain<'a, T>;
            impl<'a, T> Iterator for Iter<'a, T> { type Item = &'a T; }
            impl<'a, T> Iterator for IterMut<'a, T> { type Item = &'a mut T; }
            impl<T> Iterator for IntoIter<T> { type Item = T; }
            impl<'a, T> Iterator for Drain<'a, T> { type Item = T; }
        }
        pub mod binary_heap {
            #[derive(Clone, Debug, Default)]
            pub struct BinaryHeap<T>;
            impl<T: Ord> BinaryHeap<T> { pub fn new() -> BinaryHeap<T>; pub fn push(&mut self, item: T); pub fn pop(&mut self) -> Option<T>; pub fn peek(&self) -> Option<&T>; pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn into_sorted_vec(self) -> Vec<T>; }
        }
        pub use hash_map::HashMap; pub use hash_set::HashSet; pub use btree_map::BTreeMap; pub use btree_set::BTreeSet; pub use vec_deque::VecDeque;
        pub use binary_heap::BinaryHeap;
        #[derive(Clone, Debug, PartialEq, Eq)] pub struct TryReserveError;
    }

    pub mod array {
        pub fn from_fn<T, const N: usize, F>(cb: F) -> [T; N] where F: FnMut(usize) -> T;
        pub struct IntoIter<T, const N: usize>;
        impl<T, const N: usize> Iterator for IntoIter<T, N> { type Item = T; }
        #[derive(Debug, Display, Clone, Copy)] pub struct TryFromSliceError;
    }

    pub mod fmt {
        pub type Result = crate::result::Result<(), Error>;
        #[derive(Clone, Copy, Debug, Display, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Error;
        pub trait Debug { fn fmt(&self, f: &mut Formatter<'_>) -> Result; }
        pub trait Display { fn fmt(&self, f: &mut Formatter<'_>) -> Result; }
        pub trait Write { fn write_str(&mut self, s: &str) -> Result; fn write_char(&mut self, c: char) -> Result; fn write_fmt(&mut self, args: Arguments<'_>) -> Result; }
        pub trait LowerHex { fn fmt(&self, f: &mut Formatter<'_>) -> Result; } pub trait UpperHex { fn fmt(&self, f: &mut Formatter<'_>) -> Result; }
        pub trait Binary { fn fmt(&self, f: &mut Formatter<'_>) -> Result; } pub trait Pointer { fn fmt(&self, f: &mut Formatter<'_>) -> Result; }
        pub struct Formatter<'a>;
        impl<'a> Formatter<'a> {
            pub fn pad(&mut self, s: &str) -> Result; pub fn pad_integral(&mut self, is_nonnegative: bool, prefix: &str, buf: &str) -> Result;
            pub fn write_str(&mut self, data: &str) -> Result; pub fn write_fmt(&mut self, fmt: Arguments<'_>) -> Result; pub fn alternate(&self) -> bool;
            pub fn width(&self) -> Option<usize>; pub fn precision(&self) -> Option<usize>; pub fn fill(&self) -> char;
            pub fn debug_struct<'b>(&'b mut self, name: &str) -> DebugStruct<'b, 'a>; pub fn debug_tuple<'b>(&'b mut self, name: &str) -> DebugTuple<'b, 'a>;
            pub fn debug_list<'b>(&'b mut self) -> DebugList<'b, 'a>; pub fn debug_set<'b>(&'b mut self) -> DebugSet<'b, 'a>; pub fn debug_map<'b>(&'b mut self) -> DebugMap<'b, 'a>;
        }
        impl Write for Formatter<'_> {}
        pub struct DebugStruct<'a, 'b>; pub struct DebugTuple<'a, 'b>; pub struct DebugList<'a, 'b>; pub struct DebugSet<'a, 'b>; pub struct DebugMap<'a, 'b>;
        impl<'a, 'b> DebugStruct<'a, 'b> { pub fn field(&mut self, name: &str, value: &dyn Debug) -> &mut Self; pub fn field_with<F>(&mut self, name: &str, f: F) -> &mut Self; pub fn finish(&mut self) -> Result; pub fn finish_non_exhaustive(&mut self) -> Result; }
        impl<'a, 'b> DebugTuple<'a, 'b> { pub fn field(&mut self, value: &dyn Debug) -> &mut Self; pub fn finish(&mut self) -> Result; pub fn finish_non_exhaustive(&mut self) -> Result; }
        impl<'a, 'b> DebugList<'a, 'b> { pub fn entry(&mut self, entry: &dyn Debug) -> &mut Self; pub fn entries<D: Debug, I: IntoIterator<Item = D>>(&mut self, entries: I) -> &mut Self; pub fn finish(&mut self) -> Result; pub fn finish_non_exhaustive(&mut self) -> Result; }
        impl<'a, 'b> DebugSet<'a, 'b> { pub fn entry(&mut self, entry: &dyn Debug) -> &mut Self; pub fn entries<D: Debug, I: IntoIterator<Item = D>>(&mut self, entries: I) -> &mut Self; pub fn finish(&mut self) -> Result; }
        impl<'a, 'b> DebugMap<'a, 'b> { pub fn entry(&mut self, key: &dyn Debug, value: &dyn Debug) -> &mut Self; pub fn key(&mut self, key: &dyn Debug) -> &mut Self; pub fn value(&mut self, value: &dyn Debug) -> &mut Self; pub fn entries<K: Debug, V: Debug, I: IntoIterator<Item = (K, V)>>(&mut self, entries: I) -> &mut Self; pub fn finish(&mut self) -> Result; }
        #[derive(Clone, Copy, Debug, Display)] pub struct Arguments<'a>;
        impl<'a> Arguments<'a> { pub fn as_str(&self) -> Option<&'static str>; }
        pub fn format(args: Arguments<'_>) -> String; pub fn write(output: &mut dyn Write, args: Arguments<'_>) -> Result;
        #[derive(Clone, Copy, Debug, PartialEq, Eq)] pub enum Alignment { Left, Right, Center }
    }

    pub mod error {
        pub trait Error: Debug + Display {
            fn source(&self) -> Option<&(dyn Error + 'static)>; fn description(&self) -> &str; fn cause(&self) -> Option<&dyn Error>;
        }
        impl dyn Error { pub fn is<T: Error + 'static>(&self) -> bool; pub fn downcast_ref<T: Error + 'static>(&self) -> Option<&T>; pub fn downcast_mut<T: Error + 'static>(&mut self) -> Option<&mut T>; }
        impl<E: Error> From<E> for Box<dyn Error> {}
    }

    pub mod any {
        pub trait Any: 'static { fn type_id(&self) -> TypeId; }
        impl<T: 'static + ?Sized> Any for T {}
        impl dyn Any { pub fn is<T: Any>(&self) -> bool; pub fn downcast_ref<T: Any>(&self) -> Option<&T>; pub fn downcast_mut<T: Any>(&mut self) -> Option<&mut T>; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct TypeId;
        impl TypeId { pub fn of<T: ?Sized + 'static>() -> TypeId; }
        pub fn type_name<T: ?Sized>() -> &'static str; pub fn type_name_of_val<T: ?Sized>(_val: &T) -> &'static str;
    }

    pub mod mem {
        pub fn drop<T>(_x: T); pub fn forget<T>(t: T); pub fn take<T: Default>(dest: &mut T) -> T; pub fn replace<T>(dest: &mut T, src: T) -> T;
        pub fn swap<T>(x: &mut T, y: &mut T); pub const fn size_of<T>() -> usize; pub fn size_of_val<T: ?Sized>(val: &T) -> usize; pub const fn align_of<T>() -> usize;
        pub fn align_of_val<T: ?Sized>(val: &T) -> usize; pub unsafe fn zeroed<T>() -> T; pub unsafe fn transmute<Src, Dst>(src: Src) -> Dst;
        pub unsafe fn transmute_copy<Src, Dst>(src: &Src) -> Dst; pub fn discriminant<T>(v: &T) -> Discriminant<T>; pub const fn needs_drop<T: ?Sized>() -> bool;
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)] pub struct Discriminant<T>;
        #[derive(Clone, Copy, Debug)] pub union MaybeUninit<T> { uninit: (), value: ManuallyDrop<T> }
        impl<T> MaybeUninit<T> {
            pub const fn new(val: T) -> MaybeUninit<T>; pub const fn uninit() -> MaybeUninit<T>; pub const fn zeroed() -> MaybeUninit<T>;
            pub fn write(&mut self, val: T) -> &mut T; pub const fn as_ptr(&self) -> *const T; pub fn as_mut_ptr(&mut self) -> *mut T;
            pub unsafe fn assume_init(self) -> T; pub unsafe fn assume_init_read(&self) -> T; pub unsafe fn assume_init_drop(&mut self);
            pub unsafe fn assume_init_ref(&self) -> &T; pub unsafe fn assume_init_mut(&mut self) -> &mut T; pub fn uninit_array<const N: usize>() -> [Self; N];
        }
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct ManuallyDrop<T: ?Sized>;
        impl<T> ManuallyDrop<T> { pub const fn new(value: T) -> ManuallyDrop<T>; pub fn into_inner(slot: ManuallyDrop<T>) -> T; pub unsafe fn take(slot: &mut ManuallyDrop<T>) -> T; }
        impl<T: ?Sized> ManuallyDrop<T> { pub unsafe fn drop(slot: &mut ManuallyDrop<T>); }
        impl<T: ?Sized> Deref for ManuallyDrop<T> { type Target = T; }
        impl<T: ?Sized> DerefMut for ManuallyDrop<T> {}
        pub use crate::marker::PhantomData;
    }

    pub mod ptr {
        pub const fn null<T>() -> *const T; pub const fn null_mut<T>() -> *mut T; pub unsafe fn read<T>(src: *const T) -> T; pub unsafe fn write<T>(dst: *mut T, src: T);
        pub unsafe fn read_volatile<T>(src: *const T) -> T; pub unsafe fn write_volatile<T>(dst: *mut T, src: T); pub unsafe fn read_unaligned<T>(src: *const T) -> T;
        pub unsafe fn drop_in_place<T: ?Sized>(to_drop: *mut T); pub unsafe fn copy<T>(src: *const T, dst: *mut T, count: usize);
        pub unsafe fn copy_nonoverlapping<T>(src: *const T, dst: *mut T, count: usize); pub unsafe fn replace<T>(dst: *mut T, src: T) -> T;
        pub unsafe fn swap<T>(x: *mut T, y: *mut T); pub fn eq<T: ?Sized>(a: *const T, b: *const T) -> bool; pub fn addr_eq<T: ?Sized, U: ?Sized>(p: *const T, q: *const U) -> bool;
        pub fn slice_from_raw_parts<T>(data: *const T, len: usize) -> *const [T]; pub fn slice_from_raw_parts_mut<T>(data: *mut T, len: usize) -> *mut [T];
        pub fn without_provenance<T>(addr: usize) -> *const T; pub fn dangling<T>() -> *const T; pub fn from_ref<T: ?Sized>(r: &T) -> *const T; pub fn from_mut<T: ?Sized>(r: &mut T) -> *mut T;
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct NonNull<T: ?Sized>;
        impl<T> NonNull<T> { pub const fn dangling() -> Self; }
        impl<T: ?Sized> NonNull<T> {
            pub fn new(ptr: *mut T) -> Option<Self>; pub const unsafe fn new_unchecked(ptr: *mut T) -> Self; pub const fn as_ptr(self) -> *mut T;
            pub unsafe fn as_ref<'a>(&self) -> &'a T; pub unsafe fn as_mut<'a>(&mut self) -> &'a mut T; pub const fn cast<U>(self) -> NonNull<U>;
            pub fn from_ref(r: &T) -> Self; pub fn from_mut(r: &mut T) -> Self; pub unsafe fn add(self, count: usize) -> Self; pub fn addr(self) -> NonZero<usize>;
        }
        impl<T: ?Sized> From<&T> for NonNull<T> {} impl<T: ?Sized> From<&mut T> for NonNull<T> {}
    }

    pub mod num {
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct NonZero<T>;
        impl<T> NonZero<T> { pub const fn new(n: T) -> Option<Self>; pub const unsafe fn new_unchecked(n: T) -> Self; pub const fn get(self) -> T; }
        pub type NonZeroU8 = NonZero<u8>; pub type NonZeroU16 = NonZero<u16>; pub type NonZeroU32 = NonZero<u32>; pub type NonZeroU64 = NonZero<u64>;
        pub type NonZeroUsize = NonZero<usize>; pub type NonZeroI32 = NonZero<i32>; pub type NonZeroI64 = NonZero<i64>;
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct ParseIntError;
        impl ParseIntError { pub fn kind(&self) -> &IntErrorKind; }
        #[derive(Clone, Debug, PartialEq, Eq)] pub enum IntErrorKind { Empty, InvalidDigit, PosOverflow, NegOverflow, Zero }
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct ParseFloatError;
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq)] pub struct TryFromIntError;
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Wrapping<T>(pub T);
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Saturating<T>(pub T);
    }

    pub mod pin {
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Pin<Ptr> { pointer: Ptr }
        impl<Ptr: Deref> Pin<Ptr> {
            pub fn new(pointer: Ptr) -> Pin<Ptr>; pub unsafe fn new_unchecked(pointer: Ptr) -> Pin<Ptr>; pub fn into_inner(pin: Pin<Ptr>) -> Ptr;
            pub fn as_ref(&self) -> Pin<&Ptr::Target>; pub unsafe fn into_inner_unchecked(pin: Pin<Ptr>) -> Ptr;
        }
        impl<Ptr: DerefMut> Pin<Ptr> { pub fn as_mut(&mut self) -> Pin<&mut Ptr::Target>; pub fn set(&mut self, value: Ptr::Target); }
        impl<'a, T: ?Sized> Pin<&'a T> { pub fn get_ref(self) -> &'a T; pub unsafe fn map_unchecked<U: ?Sized, F>(self, func: F) -> Pin<&'a U> where F: FnOnce(&T) -> &U; }
        impl<'a, T: ?Sized> Pin<&'a mut T> {
            pub fn into_ref(self) -> Pin<&'a T>; pub fn get_mut(self) -> &'a mut T where T: Unpin; pub unsafe fn get_unchecked_mut(self) -> &'a mut T;
            pub unsafe fn map_unchecked_mut<U: ?Sized, F>(self, func: F) -> Pin<&'a mut U> where F: FnOnce(&mut T) -> &mut U;
        }
        impl<Ptr: Deref> Deref for Pin<Ptr> { type Target = <Ptr as Deref>::Target; }
        impl<Ptr: DerefMut> DerefMut for Pin<Ptr> {}
        impl<P: DerefMut<Target: Future>> Future for Pin<P> { type Output = <<P as Deref>::Target as Future>::Output; }
        pub macro pin($value:expr $(,)?) {}
    }

    pub mod future {
        pub trait Future { type Output; fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>; }
        pub trait IntoFuture { type Output; type IntoFuture: Future<Output = Self::Output>; fn into_future(self) -> Self::IntoFuture; }
        impl<F: Future> IntoFuture for F { type Output = F::Output; type IntoFuture = F; }
        impl<F: ?Sized + Future + Unpin> Future for &mut F { type Output = F::Output; }
        mod ready { pub fn ready<T>(t: T) -> Ready<T>; }
        mod pending { pub fn pending<T>() -> Pending<T>; }
        mod poll_fn { pub fn poll_fn<T, F>(f: F) -> PollFn<F> where F: FnMut(&mut Context<'_>) -> Poll<T>; }
        pub use ready::*; pub use pending::*; pub use poll_fn::*;
        #[derive(Clone, Debug)] pub struct Ready<T>; pub struct Pending<T>; pub struct PollFn<F>;
        impl<T> Future for Ready<T> { type Output = T; } impl<T> Ready<T> { pub fn into_inner(self) -> T; }
        impl<T> Future for Pending<T> { type Output = T; }
        impl<T, F: FnMut(&mut Context<'_>) -> Poll<T>> Future for PollFn<F> { type Output = T; }
    }

    pub mod task {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Poll<T> { Ready(T), Pending }
        impl<T> Poll<T> { pub fn map<U, F: FnOnce(T) -> U>(self, f: F) -> Poll<U>; pub const fn is_ready(&self) -> bool; pub const fn is_pending(&self) -> bool; }
        impl<T, E> Poll<Result<T, E>> { pub fn map_ok<U, F: FnOnce(T) -> U>(self, f: F) -> Poll<Result<U, E>>; pub fn map_err<U, F: FnOnce(E) -> U>(self, f: F) -> Poll<Result<T, U>>; }
        impl<T, E> Poll<Option<Result<T, E>>> { pub fn map_ok<U, F: FnOnce(T) -> U>(self, f: F) -> Poll<Option<Result<U, E>>>; }
        impl<T> From<T> for Poll<T> {}
        pub struct Context<'a>;
        impl<'a> Context<'a> { pub const fn from_waker(waker: &'a Waker) -> Self; pub const fn waker(&self) -> &'a Waker; }
        #[derive(Clone, Debug)] pub struct Waker;
        impl Waker {
            pub fn wake(self); pub fn wake_by_ref(&self); pub fn will_wake(&self, other: &Waker) -> bool; pub const unsafe fn from_raw(waker: RawWaker) -> Waker;
            pub const fn noop() -> &'static Waker; pub fn data(&self) -> *const (); pub fn vtable(&self) -> &'static RawWakerVTable;
        }
        #[derive(Debug, PartialEq)] pub struct RawWaker;
        impl RawWaker { pub const fn new(data: *const (), vtable: &'static RawWakerVTable) -> RawWaker; }
        #[derive(Debug, PartialEq, Copy, Clone)] pub struct RawWakerVTable;
        impl RawWakerVTable { pub const fn new(clone: unsafe fn(*const ()) -> RawWaker, wake: unsafe fn(*const ()), wake_by_ref: unsafe fn(*const ()), drop: unsafe fn(*const ())) -> Self; }
        pub trait Wake { fn wake(self: Arc<Self>); fn wake_by_ref(self: &Arc<Self>); }
        impl<W: Wake + Send + Sync + 'static> From<Arc<W>> for Waker {}
    }

    pub mod time {
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Duration;
        impl Duration {
            pub const ZERO: Duration; pub const MAX: Duration; pub const SECOND: Duration; pub const MILLISECOND: Duration;
            pub const fn new(secs: u64, nanos: u32) -> Duration; pub const fn from_secs(secs: u64) -> Duration; pub const fn from_millis(millis: u64) -> Duration;
            pub const fn from_micros(micros: u64) -> Duration; pub const fn from_nanos(nanos: u64) -> Duration; pub fn from_secs_f64(secs: f64) -> Duration; pub fn from_secs_f32(secs: f32) -> Duration;
            pub const fn is_zero(&self) -> bool; pub const fn as_secs(&self) -> u64; pub const fn subsec_millis(&self) -> u32; pub const fn subsec_micros(&self) -> u32;
            pub const fn subsec_nanos(&self) -> u32; pub const fn as_millis(&self) -> u128; pub const fn as_micros(&self) -> u128; pub const fn as_nanos(&self) -> u128;
            pub fn as_secs_f64(&self) -> f64; pub fn as_secs_f32(&self) -> f32; pub fn as_millis_f64(&self) -> f64;
            pub const fn checked_add(self, rhs: Duration) -> Option<Duration>; pub const fn checked_sub(self, rhs: Duration) -> Option<Duration>;
            pub const fn saturating_add(self, rhs: Duration) -> Duration; pub const fn saturating_sub(self, rhs: Duration) -> Duration;
            pub const fn checked_mul(self, rhs: u32) -> Option<Duration>; pub const fn saturating_mul(self, rhs: u32) -> Duration; pub fn mul_f64(self, rhs: f64) -> Duration;
            pub const fn checked_div(self, rhs: u32) -> Option<Duration>; pub fn abs_diff(self, other: Duration) -> Duration;
        }
        impl Add for Duration { type Output = Duration; } impl Sub for Duration { type Output = Duration; } impl Mul<u32> for Duration { type Output = Duration; } impl Div<u32> for Duration { type Output = Duration; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct Instant;
        impl Instant {
            pub fn now() -> Instant; pub fn duration_since(&self, earlier: Instant) -> Duration; pub fn checked_duration_since(&self, earlier: Instant) -> Option<Duration>;
            pub fn saturating_duration_since(&self, earlier: Instant) -> Duration; pub fn elapsed(&self) -> Duration;
            pub fn checked_add(&self, duration: Duration) -> Option<Instant>; pub fn checked_sub(&self, duration: Duration) -> Option<Instant>;
        }
        impl Add<Duration> for Instant { type Output = Instant; } impl Sub<Duration> for Instant { type Output = Instant; } impl Sub<Instant> for Instant { type Output = Duration; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct SystemTime;
        impl SystemTime {
            pub const UNIX_EPOCH: SystemTime; pub fn now() -> SystemTime; pub fn duration_since(&self, earlier: SystemTime) -> Result<Duration, SystemTimeError>;
            pub fn elapsed(&self) -> Result<Duration, SystemTimeError>; pub fn checked_add(&self, duration: Duration) -> Option<SystemTime>; pub fn checked_sub(&self, duration: Duration) -> Option<SystemTime>;
        }
        impl Add<Duration> for SystemTime { type Output = SystemTime; } impl Sub<Duration> for SystemTime { type Output = SystemTime; }
        pub const UNIX_EPOCH: SystemTime;
        #[derive(Clone, Debug, Display)] pub struct SystemTimeError;
        impl SystemTimeError { pub fn duration(&self) -> Duration; }
    }

    pub mod io {
        pub type Result<T> = crate::result::Result<T, Error>;
        #[derive(Debug, Display)]
        pub struct Error;
        impl Error {
            pub fn new<E>(kind: ErrorKind, error: E) -> Error; pub fn other<E>(error: E) -> Error; pub fn last_os_error() -> Error; pub fn from_raw_os_error(code: i32) -> Error;
            pub fn raw_os_error(&self) -> Option<i32>; pub fn get_ref(&self) -> Option<&(dyn crate::error::Error + Send + Sync + 'static)>;
            pub fn into_inner(self) -> Option<Box<dyn crate::error::Error + Send + Sync>>; pub fn kind(&self) -> ErrorKind;
        }
        impl From<ErrorKind> for Error {}
        impl crate::error::Error for Error {}
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum ErrorKind {
            NotFound, PermissionDenied, ConnectionRefused, ConnectionReset, HostUnreachable, NetworkUnreachable, ConnectionAborted, NotConnected, AddrInUse,
            AddrNotAvailable, NetworkDown, BrokenPipe, AlreadyExists, WouldBlock, NotADirectory, IsADirectory, DirectoryNotEmpty, ReadOnlyFilesystem,
            StaleNetworkFileHandle, InvalidInput, InvalidData, TimedOut, WriteZero, StorageFull, NotSeekable, QuotaExceeded, FileTooLarge, ResourceBusy,
            ExecutableFileBusy, Deadlock, CrossesDevices, TooManyLinks, InvalidFilename, ArgumentListTooLong, Interrupted, Unsupported, UnexpectedEof,
            OutOfMemory, InProgress, Other, Uncategorized,
        }
        pub trait Read {
            fn read(&mut self, buf: &mut [u8]) -> Result<usize>; fn read_vectored(&mut self, bufs: &mut [IoSliceMut<'_>]) -> Result<usize>;
            fn read_to_end(&mut self, buf: &mut Vec<u8>) -> Result<usize>; fn read_to_string(&mut self, buf: &mut String) -> Result<usize>;
            fn read_exact(&mut self, buf: &mut [u8]) -> Result<()>; fn by_ref(&mut self) -> &mut Self where Self: Sized; fn bytes(self) -> Bytes<Self> where Self: Sized;
            fn take(self, limit: u64) -> Take<Self> where Self: Sized; fn chain<R: Read>(self, next: R) -> Chain<Self, R> where Self: Sized;
        }
        pub trait Write {
            fn write(&mut self, buf: &[u8]) -> Result<usize>; fn write_vectored(&mut self, bufs: &[IoSlice<'_>]) -> Result<usize>; fn flush(&mut self) -> Result<()>;
            fn write_all(&mut self, buf: &[u8]) -> Result<()>; fn write_fmt(&mut self, fmt: fmt::Arguments<'_>) -> Result<()>; fn by_ref(&mut self) -> &mut Self where Self: Sized;
            fn is_write_vectored(&self) -> bool;
        }
        pub trait BufRead: Read {
            fn fill_buf(&mut self) -> Result<&[u8]>; fn consume(&mut self, amt: usize); fn has_data_left(&mut self) -> Result<bool>;
            fn read_until(&mut self, byte: u8, buf: &mut Vec<u8>) -> Result<usize>; fn read_line(&mut self, buf: &mut String) -> Result<usize>;
            fn lines(self) -> Lines<Self> where Self: Sized; fn split(self, byte: u8) -> Split<Self> where Self: Sized;
        }
        pub trait Seek { fn seek(&mut self, pos: SeekFrom) -> Result<u64>; fn rewind(&mut self) -> Result<()>; fn stream_position(&mut self) -> Result<u64>; }
        pub trait IsTerminal { fn is_terminal(&self) -> bool; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq)] pub enum SeekFrom { Start(u64), End(i64), Current(i64) }
        #[derive(Clone, Copy, Debug)] pub struct IoSlice<'a>;
        impl<'a> IoSlice<'a> { pub fn new(buf: &'a [u8]) -> IoSlice<'a>; pub fn advance(&mut self, n: usize); pub fn advance_slices(bufs: &mut &mut [IoSlice<'a>], n: usize); }
        impl<'a> Deref for IoSlice<'a> { type Target = [u8]; }
        #[derive(Debug)] pub struct IoSliceMut<'a>;
        impl<'a> IoSliceMut<'a> { pub fn new(buf: &'a mut [u8]) -> IoSliceMut<'a>; pub fn advance(&mut self, n: usize); }
        impl<'a> Deref for IoSliceMut<'a> { type Target = [u8]; }
        impl<'a> DerefMut for IoSliceMut<'a> {}
        #[derive(Clone, Debug, Default, PartialEq, Eq)] pub struct Cursor<T>;
        impl<T> Cursor<T> {
            pub const fn new(inner: T) -> Cursor<T>; pub fn into_inner(self) -> T; pub const fn get_ref(&self) -> &T; pub fn get_mut(&mut self) -> &mut T;
            pub const fn position(&self) -> u64; pub fn set_position(&mut self, pos: u64);
        }
        impl<T: AsRef<[u8]>> Read for Cursor<T> {} impl<T: AsRef<[u8]>> BufRead for Cursor<T> {} impl<T: AsRef<[u8]>> Seek for Cursor<T> {}
        impl Write for Cursor<Vec<u8>> {} impl Write for Cursor<&mut [u8]> {} impl Write for Cursor<&mut Vec<u8>> {}
        pub struct BufReader<R>;
        impl<R: Read> BufReader<R> { pub fn new(inner: R) -> BufReader<R>; pub fn with_capacity(capacity: usize, inner: R) -> BufReader<R>; }
        impl<R> BufReader<R> { pub fn get_ref(&self) -> &R; pub fn get_mut(&mut self) -> &mut R; pub fn buffer(&self) -> &[u8]; pub fn into_inner(self) -> R; }
        impl<R: Read> Read for BufReader<R> {} impl<R: Read> BufRead for BufReader<R> {}
        pub struct BufWriter<W: Write>;
        impl<W: Write> BufWriter<W> { pub fn new(inner: W) -> BufWriter<W>; pub fn with_capacity(capacity: usize, inner: W) -> BufWriter<W>; pub fn get_ref(&self) -> &W; pub fn get_mut(&mut self) -> &mut W; pub fn into_inner(self) -> Result<W>; }
        impl<W: Write> Write for BufWriter<W> {}
        pub struct LineWriter<W: Write>;
        pub struct Lines<B>; pub struct Split<B>; pub struct Bytes<R>; pub struct Take<T>; pub struct Chain<T, U>;
        impl<B: BufRead> Iterator for Lines<B> { type Item = Result<String>; }
        impl<B: BufRead> Iterator for Split<B> { type Item = Result<Vec<u8>>; }
        impl<R: Read> Iterator for Bytes<R> { type Item = Result<u8>; }
        impl<T: Read> Read for Take<T> {}
        mod stdio {
            pub fn stdin() -> Stdin; pub fn stdout() -> Stdout; pub fn stderr() -> Stderr;
            pub struct Stdin; pub struct Stdout; pub struct Stderr; pub struct StdinLock<'a>; pub struct StdoutLock<'a>; pub struct StderrLock<'a>;
            impl Stdin { pub fn lock(&self) -> StdinLock<'static>; pub fn read_line(&self, buf: &mut String) -> Result<usize>; pub fn lines(self) -> Lines<StdinLock<'static>>; }
            impl Stdout { pub fn lock(&self) -> StdoutLock<'static>; }
            impl Stderr { pub fn lock(&self) -> StderrLock<'static>; }
            impl Read for Stdin {} impl Read for &Stdin {} impl Write for Stdout {} impl Write for &Stdout {} impl Write for Stderr {} impl Write for &Stderr {}
            impl Read for StdinLock<'_> {} impl BufRead for StdinLock<'_> {} impl Write for StdoutLock<'_> {} impl Write for StderrLock<'_> {}
            impl IsTerminal for Stdin {} impl IsTerminal for Stdout {} impl IsTerminal for Stderr {}
        }
        pub use stdio::*;
        pub fn copy<R: ?Sized + Read, W: ?Sized + Write>(reader: &mut R, writer: &mut W) -> Result<u64>;
        pub fn empty() -> Empty; pub fn sink() -> Sink; pub fn repeat(byte: u8) -> Repeat; pub fn read_to_string<R: Read>(reader: R) -> Result<String>;
        pub struct Empty; pub struct Sink; pub struct Repeat;
        impl Read for Empty {} impl Write for Sink {} impl Read for Repeat {}
        pub mod prelude { pub use super::{Read, Write, BufRead, Seek}; }
        impl Read for &[u8] {} impl BufRead for &[u8] {} impl Write for &mut [u8] {}
        impl<R: Read + ?Sized> Read for &mut R {} impl<W: Write + ?Sized> Write for &mut W {} impl<R: Read + ?Sized> Read for Box<R> {} impl<W: Write + ?Sized> Write for Box<W> {}
    }

    pub mod fs {
        #[derive(Debug)] pub struct File;
        impl File {
            pub fn open<P: AsRef<Path>>(path: P) -> io::Result<File>; pub fn create<P: AsRef<Path>>(path: P) -> io::Result<File>;
            pub fn create_new<P: AsRef<Path>>(path: P) -> io::Result<File>; pub fn options() -> OpenOptions; pub fn sync_all(&self) -> io::Result<()>;
            pub fn sync_data(&self) -> io::Result<()>; pub fn set_len(&self, size: u64) -> io::Result<()>; pub fn metadata(&self) -> io::Result<Metadata>;
            pub fn try_clone(&self) -> io::Result<File>; pub fn set_permissions(&self, perm: Permissions) -> io::Result<()>; pub fn lock(&self) -> io::Result<()>; pub fn unlock(&self) -> io::Result<()>;
        }
        impl io::Read for File {} impl io::Write for File {} impl io::Seek for File {} impl io::Read for &File {} impl io::Write for &File {} impl io::Seek for &File {}
        #[derive(Clone, Debug)] pub struct OpenOptions;
        impl OpenOptions {
            pub fn new() -> Self; pub fn read(&mut self, read: bool) -> &mut Self; pub fn write(&mut self, write: bool) -> &mut Self; pub fn append(&mut self, append: bool) -> &mut Self;
            pub fn truncate(&mut self, truncate: bool) -> &mut Self; pub fn create(&mut self, create: bool) -> &mut Self; pub fn create_new(&mut self, create_new: bool) -> &mut Self;
            pub fn open<P: AsRef<Path>>(&self, path: P) -> io::Result<File>;
        }
        #[derive(Clone, Debug)] pub struct Metadata;
        impl Metadata {
            pub fn file_type(&self) -> FileType; pub fn is_dir(&self) -> bool; pub fn is_file(&self) -> bool; pub fn is_symlink(&self) -> bool; pub fn len(&self) -> u64;
            pub fn permissions(&self) -> Permissions; pub fn modified(&self) -> io::Result<SystemTime>; pub fn accessed(&self) -> io::Result<SystemTime>; pub fn created(&self) -> io::Result<SystemTime>;
        }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)] pub struct FileType;
        impl FileType { pub fn is_dir(&self) -> bool; pub fn is_file(&self) -> bool; pub fn is_symlink(&self) -> bool; }
        #[derive(Clone, Debug, PartialEq, Eq)] pub struct Permissions;
        impl Permissions { pub fn readonly(&self) -> bool; pub fn set_readonly(&mut self, readonly: bool); }
        #[derive(Debug)] pub struct ReadDir;
        impl Iterator for ReadDir { type Item = io::Result<DirEntry>; }
        #[derive(Debug)] pub struct DirEntry;
        impl DirEntry { pub fn path(&self) -> PathBuf; pub fn metadata(&self) -> io::Result<Metadata>; pub fn file_type(&self) -> io::Result<FileType>; pub fn file_name(&self) -> OsString; }
        #[derive(Debug)] pub struct DirBuilder;
        impl DirBuilder { pub fn new() -> DirBuilder; pub fn recursive(&mut self, recursive: bool) -> &mut Self; pub fn create<P: AsRef<Path>>(&self, path: P) -> io::Result<()>; }
        pub fn read<P: AsRef<Path>>(path: P) -> io::Result<Vec<u8>>; pub fn read_to_string<P: AsRef<Path>>(path: P) -> io::Result<String>;
        pub fn write<P: AsRef<Path>, C: AsRef<[u8]>>(path: P, contents: C) -> io::Result<()>; pub fn remove_file<P: AsRef<Path>>(path: P) -> io::Result<()>;
        pub fn metadata<P: AsRef<Path>>(path: P) -> io::Result<Metadata>; pub fn symlink_metadata<P: AsRef<Path>>(path: P) -> io::Result<Metadata>;
        pub fn rename<P: AsRef<Path>, Q: AsRef<Path>>(from: P, to: Q) -> io::Result<()>; pub fn copy<P: AsRef<Path>, Q: AsRef<Path>>(from: P, to: Q) -> io::Result<u64>;
        pub fn create_dir<P: AsRef<Path>>(path: P) -> io::Result<()>; pub fn create_dir_all<P: AsRef<Path>>(path: P) -> io::Result<()>;
        pub fn remove_dir<P: AsRef<Path>>(path: P) -> io::Result<()>; pub fn remove_dir_all<P: AsRef<Path>>(path: P) -> io::Result<()>;
        pub fn read_dir<P: AsRef<Path>>(path: P) -> io::Result<ReadDir>; pub fn canonicalize<P: AsRef<Path>>(path: P) -> io::Result<PathBuf>;
        pub fn set_permissions<P: AsRef<Path>>(path: P, perm: Permissions) -> io::Result<()>; pub fn exists<P: AsRef<Path>>(path: P) -> io::Result<bool>;
        pub fn hard_link<P: AsRef<Path>, Q: AsRef<Path>>(original: P, link: Q) -> io::Result<()>; pub fn read_link<P: AsRef<Path>>(path: P) -> io::Result<PathBuf>;
    }

    pub mod path {
        #[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Path;
        impl Path {
            pub fn new<S: AsRef<OsStr> + ?Sized>(s: &S) -> &Path; pub fn as_os_str(&self) -> &OsStr; pub fn to_str(&self) -> Option<&str>;
            pub fn to_string_lossy(&self) -> Cow<'_, str>; pub fn to_path_buf(&self) -> PathBuf; pub fn is_absolute(&self) -> bool; pub fn is_relative(&self) -> bool;
            pub fn has_root(&self) -> bool; pub fn parent(&self) -> Option<&Path>; pub fn ancestors(&self) -> Ancestors<'_>; pub fn file_name(&self) -> Option<&OsStr>;
            pub fn strip_prefix<P: AsRef<Path>>(&self, base: P) -> Result<&Path, StripPrefixError>; pub fn starts_with<P: AsRef<Path>>(&self, base: P) -> bool;
            pub fn ends_with<P: AsRef<Path>>(&self, child: P) -> bool; pub fn file_stem(&self) -> Option<&OsStr>; pub fn extension(&self) -> Option<&OsStr>;
            pub fn join<P: AsRef<Path>>(&self, path: P) -> PathBuf; pub fn with_file_name<S: AsRef<OsStr>>(&self, file_name: S) -> PathBuf;
            pub fn with_extension<S: AsRef<OsStr>>(&self, extension: S) -> PathBuf; pub fn components(&self) -> Components<'_>; pub fn iter(&self) -> Iter<'_>;
            pub fn display(&self) -> Display<'_>; pub fn metadata(&self) -> io::Result<Metadata>; pub fn canonicalize(&self) -> io::Result<PathBuf>;
            pub fn read_dir(&self) -> io::Result<ReadDir>; pub fn exists(&self) -> bool; pub fn try_exists(&self) -> io::Result<bool>; pub fn is_file(&self) -> bool;
            pub fn is_dir(&self) -> bool; pub fn is_symlink(&self) -> bool;
        }
        impl ToOwned for Path { type Owned = PathBuf; }
        impl AsRef<Path> for Path {} impl AsRef<OsStr> for Path {}
        #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct PathBuf;
        impl PathBuf {
            pub fn new() -> PathBuf; pub fn with_capacity(capacity: usize) -> PathBuf; pub fn as_path(&self) -> &Path; pub fn push<P: AsRef<Path>>(&mut self, path: P);
            pub fn pop(&mut self) -> bool; pub fn set_file_name<S: AsRef<OsStr>>(&mut self, file_name: S); pub fn set_extension<S: AsRef<OsStr>>(&mut self, extension: S) -> bool;
            pub fn into_os_string(self) -> OsString; pub fn into_boxed_path(self) -> Box<Path>;
        }
        impl Deref for PathBuf { type Target = Path; }
        impl AsRef<Path> for PathBuf {} impl AsRef<OsStr> for PathBuf {} impl From<String> for PathBuf {} impl From<&str> for PathBuf {} impl From<OsString> for PathBuf {}
        impl<P: AsRef<Path>> FromIterator<P> for PathBuf {}
        pub struct Display<'a>; pub struct Ancestors<'a>; pub struct Components<'a>; pub struct Iter<'a>;
        impl fmt::Display for Display<'_> {}
        impl<'a> Iterator for Ancestors<'a> { type Item = &'a Path; }
        impl<'a> Iterator for Components<'a> { type Item = Component<'a>; }
        impl<'a> Iterator for Iter<'a> { type Item = &'a OsStr; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub enum Component<'a> { Prefix(PrefixComponent<'a>), RootDir, CurDir, ParentDir, Normal(&'a OsStr) }
        impl<'a> Component<'a> { pub fn as_os_str(self) -> &'a OsStr; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct PrefixComponent<'a>;
        #[derive(Debug, Display, Clone, PartialEq, Eq)] pub struct StripPrefixError;
        pub const MAIN_SEPARATOR: char; pub const MAIN_SEPARATOR_STR: &str;
        pub fn absolute<P: AsRef<Path>>(path: P) -> io::Result<PathBuf>;
    }

    pub mod ffi {
        #[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct OsStr;
        impl OsStr {
            pub fn new<S: AsRef<OsStr> + ?Sized>(s: &S) -> &OsStr; pub fn to_str(&self) -> Option<&str>; pub fn to_string_lossy(&self) -> Cow<'_, str>;
            pub fn to_os_string(&self) -> OsString; pub fn is_empty(&self) -> bool; pub fn len(&self) -> usize; pub fn as_encoded_bytes(&self) -> &[u8]; pub fn display(&self) -> Display<'_>;
            pub fn to_ascii_lowercase(&self) -> OsString; pub fn eq_ignore_ascii_case<S: AsRef<OsStr>>(&self, other: S) -> bool;
        }
        impl ToOwned for OsStr { type Owned = OsString; }
        impl AsRef<OsStr> for OsStr {} impl AsRef<Path> for OsStr {}
        #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct OsString;
        impl OsString {
            pub fn new() -> OsString; pub fn as_os_str(&self) -> &OsStr; pub fn into_string(self) -> Result<String, OsString>; pub fn push<T: AsRef<OsStr>>(&mut self, s: T);
            pub fn with_capacity(capacity: usize) -> OsString; pub fn clear(&mut self); pub fn into_encoded_bytes(self) -> Vec<u8>;
        }
        impl Deref for OsString { type Target = OsStr; }
        impl AsRef<OsStr> for OsString {} impl AsRef<Path> for OsString {} impl From<String> for OsString {} impl<T: ?Sized + AsRef<OsStr>> From<&T> for OsString {}
        #[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct CStr;
        impl CStr {
            pub unsafe fn from_ptr<'a>(ptr: *const c_char) -> &'a CStr; pub fn from_bytes_with_nul(bytes: &[u8]) -> Result<&Self, FromBytesWithNulError>;
            pub const fn as_ptr(&self) -> *const c_char; pub fn to_bytes(&self) -> &[u8]; pub fn to_bytes_with_nul(&self) -> &[u8]; pub fn to_str(&self) -> Result<&str, Utf8Error>;
            pub fn to_string_lossy(&self) -> Cow<'_, str>; pub fn count_bytes(&self) -> usize; pub fn is_empty(&self) -> bool;
        }
        impl ToOwned for CStr { type Owned = CString; }
        #[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct CString;
        impl CString {
            pub fn new<T: Into<Vec<u8>>>(t: T) -> Result<CString, NulError>; pub fn into_raw(self) -> *mut c_char; pub unsafe fn from_raw(ptr: *mut c_char) -> CString;
            pub fn into_string(self) -> Result<String, IntoStringError>; pub fn into_bytes(self) -> Vec<u8>; pub fn as_bytes(&self) -> &[u8]; pub fn as_c_str(&self) -> &CStr;
        }
        impl Deref for CString { type Target = CStr; }
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct NulError;
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct FromBytesWithNulError;
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct IntoStringError;
        pub struct Display<'a>;
        pub type c_char = i8; pub type c_schar = i8; pub type c_uchar = u8; pub type c_short = i16; pub type c_ushort = u16; pub type c_int = i32; pub type c_uint = u32;
        pub type c_long = i64; pub type c_ulong = u64; pub type c_longlong = i64; pub type c_ulonglong = u64; pub type c_float = f32; pub type c_double = f64;
        #[derive(Debug)] pub enum c_void {}
    }

    pub mod env {
        pub fn var<K: AsRef<OsStr>>(key: K) -> Result<String, VarError>; pub fn var_os<K: AsRef<OsStr>>(key: K) -> Option<OsString>;
        pub unsafe fn set_var<K: AsRef<OsStr>, V: AsRef<OsStr>>(key: K, value: V); pub unsafe fn remove_var<K: AsRef<OsStr>>(key: K);
        pub fn vars() -> Vars; pub fn vars_os() -> VarsOs; pub fn args() -> Args; pub fn args_os() -> ArgsOs; pub fn current_dir() -> io::Result<PathBuf>;
        pub fn set_current_dir<P: AsRef<Path>>(path: P) -> io::Result<()>; pub fn current_exe() -> io::Result<PathBuf>; pub fn temp_dir() -> PathBuf; pub fn home_dir() -> Option<PathBuf>;
        pub fn split_paths<T: AsRef<OsStr> + ?Sized>(unparsed: &T) -> SplitPaths<'_>; pub fn join_paths<I, T>(paths: I) -> Result<OsString, JoinPathsError>;
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub enum VarError { NotPresent, NotUnicode(OsString) }
        pub struct Vars; pub struct VarsOs; pub struct Args; pub struct ArgsOs; pub struct SplitPaths<'a>; #[derive(Debug, Display)] pub struct JoinPathsError;
        impl Iterator for Vars { type Item = (String, String); } impl Iterator for VarsOs { type Item = (OsString, OsString); }
        impl Iterator for Args { type Item = String; } impl Iterator for ArgsOs { type Item = OsString; } impl<'a> Iterator for SplitPaths<'a> { type Item = PathBuf; }
        impl ExactSizeIterator for Args {} impl DoubleEndedIterator for Args {}
        pub mod consts { pub const ARCH: &str; pub const FAMILY: &str; pub const OS: &str; pub const DLL_EXTENSION: &str; pub const EXE_SUFFIX: &str; }
    }

    pub mod process {
        #[derive(Debug)] pub struct Command;
        impl Command {
            pub fn new<S: AsRef<OsStr>>(program: S) -> Command; pub fn arg<S: AsRef<OsStr>>(&mut self, arg: S) -> &mut Command;
            pub fn args<I, S>(&mut self, args: I) -> &mut Command where I: IntoIterator<Item = S>, S: AsRef<OsStr>;
            pub fn env<K: AsRef<OsStr>, V: AsRef<OsStr>>(&mut self, key: K, val: V) -> &mut Command; pub fn envs<I, K, V>(&mut self, vars: I) -> &mut Command;
            pub fn env_remove<K: AsRef<OsStr>>(&mut self, key: K) -> &mut Command; pub fn env_clear(&mut self) -> &mut Command;
            pub fn current_dir<P: AsRef<Path>>(&mut self, dir: P) -> &mut Command; pub fn stdin<T: Into<Stdio>>(&mut self, cfg: T) -> &mut Command;
            pub fn stdout<T: Into<Stdio>>(&mut self, cfg: T) -> &mut Command; pub fn stderr<T: Into<Stdio>>(&mut self, cfg: T) -> &mut Command;
            pub fn spawn(&mut self) -> io::Result<Child>; pub fn output(&mut self) -> io::Result<Output>; pub fn status(&mut self) -> io::Result<ExitStatus>;
            pub fn get_program(&self) -> &OsStr; pub fn get_args(&self) -> CommandArgs<'_>; pub fn get_current_dir(&self) -> Option<&Path>;
        }
        pub struct CommandArgs<'a>;
        impl<'a> Iterator for CommandArgs<'a> { type Item = &'a OsStr; }
        #[derive(Debug)] pub struct Stdio;
        impl Stdio { pub fn piped() -> Stdio; pub fn inherit() -> Stdio; pub fn null() -> Stdio; }
        impl From<ChildStdin> for Stdio {} impl From<ChildStdout> for Stdio {} impl From<ChildStderr> for Stdio {} impl From<File> for Stdio {}
        #[derive(Debug)] pub struct Child { pub stdin: Option<ChildStdin>, pub stdout: Option<ChildStdout>, pub stderr: Option<ChildStderr> }
        impl Child {
            pub fn kill(&mut self) -> io::Result<()>; pub fn id(&self) -> u32; pub fn wait(&mut self) -> io::Result<ExitStatus>;
            pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>>; pub fn wait_with_output(self) -> io::Result<Output>;
        }
        #[derive(Debug)] pub struct ChildStdin; #[derive(Debug)] pub struct ChildStdout; #[derive(Debug)] pub struct ChildStderr;
        impl io::Write for ChildStdin {} impl io::Read for ChildStdout {} impl io::Read for ChildStderr {}
        #[derive(Clone, Debug, PartialEq, Eq)] pub struct Output { pub status: ExitStatus, pub stdout: Vec<u8>, pub stderr: Vec<u8> }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq)] pub struct ExitStatus;
        impl ExitStatus { pub fn success(&self) -> bool; pub fn code(&self) -> Option<i32>; pub fn exit_ok(&self) -> Result<(), ExitStatusError>; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq)] pub struct ExitStatusError;
        #[derive(Clone, Copy, Debug, PartialEq, Eq)] pub struct ExitCode;
        impl ExitCode { pub const SUCCESS: ExitCode; pub const FAILURE: ExitCode; pub fn exit_process(self) -> !; }
        impl From<u8> for ExitCode {}
        pub trait Termination { fn report(self) -> ExitCode; }
        pub fn exit(code: i32) -> !; pub fn abort() -> !; pub fn id() -> u32;
    }

    pub mod thread {
        mod functions {
            pub fn spawn<F, T>(f: F) -> JoinHandle<T> where F: FnOnce() -> T + Send + 'static, T: Send + 'static;
            pub fn sleep(dur: Duration); pub fn sleep_ms(ms: u32); pub fn yield_now(); pub fn panicking() -> bool; pub fn park(); pub fn park_timeout(dur: Duration);
            pub fn available_parallelism() -> io::Result<NonZero<usize>>;
            pub fn scope<'env, F, T>(f: F) -> T where F: for<'scope> FnOnce(&'scope Scope<'scope, 'env>) -> T;
        }
        mod current { pub fn current() -> Thread; }
        pub use functions::*; pub use current::*;
        #[derive(Debug)] pub struct Builder;
        impl Builder {
            pub fn new() -> Builder; pub fn name(self, name: String) -> Builder; pub fn stack_size(self, size: usize) -> Builder;
            pub fn spawn<F, T>(self, f: F) -> io::Result<JoinHandle<T>> where F: FnOnce() -> T + Send + 'static, T: Send + 'static;
            pub fn spawn_scoped<'scope, 'env, F, T>(self, scope: &'scope Scope<'scope, 'env>, f: F) -> io::Result<ScopedJoinHandle<'scope, T>>;
        }
        #[derive(Debug)] pub struct JoinHandle<T>;
        impl<T> JoinHandle<T> { pub fn join(self) -> Result<T>; pub fn thread(&self) -> &Thread; pub fn is_finished(&self) -> bool; }
        pub struct Scope<'scope, 'env>;
        impl<'scope, 'env> Scope<'scope, 'env> { pub fn spawn<F, T>(&'scope self, f: F) -> ScopedJoinHandle<'scope, T> where F: FnOnce() -> T + Send + 'scope; }
        pub struct ScopedJoinHandle<'scope, T>;
        impl<'scope, T> ScopedJoinHandle<'scope, T> { pub fn join(self) -> Result<T>; }
        #[derive(Clone, Debug)] pub struct Thread;
        impl Thread { pub fn id(&self) -> ThreadId; pub fn name(&self) -> Option<&str>; pub fn unpark(&self); }
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct ThreadId;
        impl ThreadId { pub fn as_u64(&self) -> NonZero<u64>; }
        pub type Result<T> = crate::result::Result<T, Box<dyn Any + Send + 'static>>;
        pub struct LocalKey<T: 'static>;
        impl<T: 'static> LocalKey<T> {
            pub fn with<F, R>(&'static self, f: F) -> R where F: FnOnce(&T) -> R;
            pub fn try_with<F, R>(&'static self, f: F) -> crate::result::Result<R, AccessError> where F: FnOnce(&T) -> R;
            pub fn set(&'static self, value: T); pub fn get(&'static self) -> T where T: Copy; pub fn take(&'static self) -> T where T: Default; pub fn replace(&'static self, value: T) -> T;
            pub fn with_borrow<F, R>(&'static self, f: F) -> R; pub fn with_borrow_mut<F, R>(&'static self, f: F) -> R;
        }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq)] pub struct AccessError;
    }

    pub mod net {
        #[derive(Debug)] pub struct TcpStream;
        impl TcpStream {
            pub fn connect<A: ToSocketAddrs>(addr: A) -> io::Result<TcpStream>; pub fn connect_timeout(addr: &SocketAddr, timeout: Duration) -> io::Result<TcpStream>;
            pub fn peer_addr(&self) -> io::Result<SocketAddr>; pub fn local_addr(&self) -> io::Result<SocketAddr>; pub fn shutdown(&self, how: Shutdown) -> io::Result<()>;
            pub fn try_clone(&self) -> io::Result<TcpStream>; pub fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()>; pub fn set_write_timeout(&self, dur: Option<Duration>) -> io::Result<()>;
            pub fn peek(&self, buf: &mut [u8]) -> io::Result<usize>; pub fn set_nodelay(&self, nodelay: bool) -> io::Result<()>; pub fn nodelay(&self) -> io::Result<bool>;
            pub fn set_ttl(&self, ttl: u32) -> io::Result<()>; pub fn take_error(&self) -> io::Result<Option<io::Error>>; pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>;
        }
        impl io::Read for TcpStream {} impl io::Write for TcpStream {} impl io::Read for &TcpStream {} impl io::Write for &TcpStream {}
        #[derive(Debug)] pub struct TcpListener;
        impl TcpListener {
            pub fn bind<A: ToSocketAddrs>(addr: A) -> io::Result<TcpListener>; pub fn local_addr(&self) -> io::Result<SocketAddr>; pub fn try_clone(&self) -> io::Result<TcpListener>;
            pub fn accept(&self) -> io::Result<(TcpStream, SocketAddr)>; pub fn incoming(&self) -> Incoming<'_>; pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>;
        }
        pub struct Incoming<'a>;
        impl<'a> Iterator for Incoming<'a> { type Item = io::Result<TcpStream>; }
        #[derive(Debug)] pub struct UdpSocket;
        impl UdpSocket {
            pub fn bind<A: ToSocketAddrs>(addr: A) -> io::Result<UdpSocket>; pub fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)>;
            pub fn send_to<A: ToSocketAddrs>(&self, buf: &[u8], addr: A) -> io::Result<usize>; pub fn local_addr(&self) -> io::Result<SocketAddr>;
            pub fn connect<A: ToSocketAddrs>(&self, addr: A) -> io::Result<()>; pub fn send(&self, buf: &[u8]) -> io::Result<usize>; pub fn recv(&self, buf: &mut [u8]) -> io::Result<usize>;
            pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>; pub fn set_broadcast(&self, broadcast: bool) -> io::Result<()>;
        }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub enum SocketAddr { V4(SocketAddrV4), V6(SocketAddrV6) }
        impl SocketAddr {
            pub fn new(ip: IpAddr, port: u16) -> SocketAddr; pub const fn ip(&self) -> IpAddr; pub const fn port(&self) -> u16; pub fn set_port(&mut self, new_port: u16);
            pub fn set_ip(&mut self, new_ip: IpAddr); pub const fn is_ipv4(&self) -> bool; pub const fn is_ipv6(&self) -> bool;
        }
        impl FromStr for SocketAddr { type Err = AddrParseError; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct SocketAddrV4;
        impl SocketAddrV4 { pub const fn new(ip: Ipv4Addr, port: u16) -> SocketAddrV4; pub const fn ip(&self) -> &Ipv4Addr; pub const fn port(&self) -> u16; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct SocketAddrV6;
        impl SocketAddrV6 { pub const fn new(ip: Ipv6Addr, port: u16, flowinfo: u32, scope_id: u32) -> SocketAddrV6; pub const fn ip(&self) -> &Ipv6Addr; pub const fn port(&self) -> u16; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub enum IpAddr { V4(Ipv4Addr), V6(Ipv6Addr) }
        impl IpAddr { pub const fn is_loopback(&self) -> bool; pub const fn is_unspecified(&self) -> bool; pub const fn is_ipv4(&self) -> bool; pub const fn is_ipv6(&self) -> bool; }
        impl FromStr for IpAddr { type Err = AddrParseError; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Ipv4Addr;
        impl Ipv4Addr {
            pub const LOCALHOST: Self; pub const UNSPECIFIED: Self; pub const BROADCAST: Self; pub const fn new(a: u8, b: u8, c: u8, d: u8) -> Ipv4Addr;
            pub const fn octets(&self) -> [u8; 4]; pub const fn is_loopback(&self) -> bool; pub const fn is_private(&self) -> bool; pub const fn is_unspecified(&self) -> bool;
            pub const fn is_link_local(&self) -> bool; pub const fn to_ipv6_mapped(&self) -> Ipv6Addr; pub const fn to_bits(self) -> u32;
        }
        impl FromStr for Ipv4Addr { type Err = AddrParseError; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Ipv6Addr;
        impl Ipv6Addr {
            pub const LOCALHOST: Self; pub const UNSPECIFIED: Self; pub const fn new(a: u16, b: u16, c: u16, d: u16, e: u16, f: u16, g: u16, h: u16) -> Ipv6Addr;
            pub const fn segments(&self) -> [u16; 8]; pub const fn octets(&self) -> [u8; 16]; pub const fn is_loopback(&self) -> bool; pub const fn to_ipv4_mapped(&self) -> Option<Ipv4Addr>;
        }
        impl FromStr for Ipv6Addr { type Err = AddrParseError; }
        #[derive(Clone, Copy, Debug, PartialEq, Eq)] pub enum Shutdown { Read, Write, Both }
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct AddrParseError;
        pub trait ToSocketAddrs { type Iter: Iterator<Item = SocketAddr>; fn to_socket_addrs(&self) -> io::Result<Self::Iter>; }
        impl ToSocketAddrs for SocketAddr { type Iter = crate::option::IntoIter<SocketAddr>; }
        impl ToSocketAddrs for str { type Iter = crate::vec::IntoIter<SocketAddr>; }
        impl ToSocketAddrs for String { type Iter = crate::vec::IntoIter<SocketAddr>; }
        impl ToSocketAddrs for (&str, u16) { type Iter = crate::vec::IntoIter<SocketAddr>; }
    }

    pub mod os {
        pub mod fd {
            pub type RawFd = i32;
            pub trait AsRawFd { fn as_raw_fd(&self) -> RawFd; }
            pub trait FromRawFd { unsafe fn from_raw_fd(fd: RawFd) -> Self; }
            pub trait IntoRawFd { fn into_raw_fd(self) -> RawFd; }
            pub trait AsFd { fn as_fd(&self) -> BorrowedFd<'_>; }
            #[derive(Clone, Copy, Debug)] pub struct BorrowedFd<'fd>;
            impl BorrowedFd<'_> { pub const unsafe fn borrow_raw(fd: RawFd) -> Self; pub fn try_clone_to_owned(&self) -> io::Result<OwnedFd>; }
            #[derive(Debug)] pub struct OwnedFd;
            impl OwnedFd { pub fn try_clone(&self) -> io::Result<Self>; }
            impl AsRawFd for BorrowedFd<'_> {} impl AsRawFd for OwnedFd {} impl IntoRawFd for OwnedFd {} impl FromRawFd for OwnedFd {} impl AsFd for OwnedFd {} impl AsFd for BorrowedFd<'_> {}
            impl AsRawFd for File {} impl FromRawFd for File {} impl IntoRawFd for File {} impl AsFd for File {}
            impl AsRawFd for TcpStream {} impl FromRawFd for TcpStream {} impl IntoRawFd for TcpStream {} impl AsFd for TcpStream {}
            impl AsRawFd for TcpListener {} impl FromRawFd for TcpListener {} impl IntoRawFd for TcpListener {} impl AsFd for TcpListener {}
            impl AsRawFd for UdpSocket {} impl FromRawFd for UdpSocket {} impl IntoRawFd for UdpSocket {} impl AsFd for UdpSocket {}
            impl AsRawFd for i32 {}
            impl<T: AsRawFd> AsRawFd for &T {} impl<T: AsFd> AsFd for &T {}
        }
        pub mod raw { pub use crate::ffi::{c_char, c_schar, c_uchar, c_short, c_ushort, c_int, c_uint, c_long, c_ulong, c_longlong, c_ulonglong, c_float, c_double, c_void}; }
        pub mod unix {
            pub mod io { pub use crate::os::fd::*; }
            pub mod prelude { pub use crate::os::fd::*; pub use super::process::{CommandExt, ExitStatusExt}; pub use super::fs::{OpenOptionsExt, PermissionsExt, MetadataExt}; pub use super::ffi::{OsStrExt, OsStringExt}; }
            pub mod net {
                #[derive(Debug)] pub struct UnixStream;
                impl UnixStream {
                    pub fn connect<P: AsRef<Path>>(path: P) -> io::Result<UnixStream>; pub fn pair() -> io::Result<(UnixStream, UnixStream)>;
                    pub fn try_clone(&self) -> io::Result<UnixStream>; pub fn local_addr(&self) -> io::Result<SocketAddr>; pub fn peer_addr(&self) -> io::Result<SocketAddr>;
                    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()>; pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
                    pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>; pub fn shutdown(&self, how: Shutdown) -> io::Result<()>; pub fn take_error(&self) -> io::Result<Option<io::Error>>;
                }
                impl io::Read for UnixStream {} impl io::Write for UnixStream {} impl io::Read for &UnixStream {} impl io::Write for &UnixStream {}
                impl AsRawFd for UnixStream {} impl FromRawFd for UnixStream {} impl IntoRawFd for UnixStream {} impl AsFd for UnixStream {}
                #[derive(Debug)] pub struct UnixListener;
                impl UnixListener {
                    pub fn bind<P: AsRef<Path>>(path: P) -> io::Result<UnixListener>; pub fn accept(&self) -> io::Result<(UnixStream, SocketAddr)>;
                    pub fn local_addr(&self) -> io::Result<SocketAddr>; pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>; pub fn incoming(&self) -> Incoming<'_>;
                    pub fn try_clone(&self) -> io::Result<UnixListener>;
                }
                impl AsRawFd for UnixListener {} impl FromRawFd for UnixListener {} impl IntoRawFd for UnixListener {} impl AsFd for UnixListener {}
                pub struct Incoming<'a>;
                impl<'a> Iterator for Incoming<'a> { type Item = io::Result<UnixStream>; }
                #[derive(Debug)] pub struct UnixDatagram;
                impl UnixDatagram {
                    pub fn bind<P: AsRef<Path>>(path: P) -> io::Result<UnixDatagram>; pub fn unbound() -> io::Result<UnixDatagram>; pub fn pair() -> io::Result<(UnixDatagram, UnixDatagram)>;
                    pub fn connect<P: AsRef<Path>>(&self, path: P) -> io::Result<()>; pub fn send(&self, buf: &[u8]) -> io::Result<usize>; pub fn recv(&self, buf: &mut [u8]) -> io::Result<usize>;
                    pub fn send_to<P: AsRef<Path>>(&self, buf: &[u8], path: P) -> io::Result<usize>; pub fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)>;
                    pub fn local_addr(&self) -> io::Result<SocketAddr>; pub fn peer_addr(&self) -> io::Result<SocketAddr>; pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>;
                    pub fn shutdown(&self, how: Shutdown) -> io::Result<()>;
                }
                impl AsRawFd for UnixDatagram {} impl FromRawFd for UnixDatagram {} impl IntoRawFd for UnixDatagram {} impl AsFd for UnixDatagram {}
                #[derive(Clone, Debug)] pub struct SocketAddr;
                impl SocketAddr { pub fn is_unnamed(&self) -> bool; pub fn as_pathname(&self) -> Option<&Path>; pub fn from_pathname<P: AsRef<Path>>(path: P) -> io::Result<SocketAddr>; }
            }
            pub mod process {
                pub trait CommandExt: Sealed {
                    fn uid(&mut self, id: u32) -> &mut Command; fn gid(&mut self, id: u32) -> &mut Command; fn groups(&mut self, groups: &[u32]) -> &mut Command;
                    unsafe fn pre_exec<F>(&mut self, f: F) -> &mut Command where F: FnMut() -> io::Result<()> + Send + Sync + 'static;
                    fn exec(&mut self) -> io::Error; fn arg0<S>(&mut self, arg: S) -> &mut Command where S: AsRef<OsStr>; fn process_group(&mut self, pgroup: i32) -> &mut Command;
                }
                impl CommandExt for Command {}
                pub trait ExitStatusExt { fn from_raw(raw: i32) -> Self; fn signal(&self) -> Option<i32>; fn core_dumped(&self) -> bool; fn into_raw(self) -> i32; }
                impl ExitStatusExt for ExitStatus {}
                pub trait Sealed {}
            }
            pub mod fs {
                pub trait OpenOptionsExt { fn mode(&mut self, mode: u32) -> &mut Self; fn custom_flags(&mut self, flags: i32) -> &mut Self; }
                impl OpenOptionsExt for OpenOptions {}
                pub trait DirBuilderExt { fn mode(&mut self, mode: u32) -> &mut Self; }
                impl DirBuilderExt for DirBuilder {}
                pub trait PermissionsExt { fn mode(&self) -> u32; fn set_mode(&mut self, mode: u32); fn from_mode(mode: u32) -> Self; }
                impl PermissionsExt for Permissions {}
                pub trait MetadataExt { fn dev(&self) -> u64; fn ino(&self) -> u64; fn mode(&self) -> u32; fn uid(&self) -> u32; fn gid(&self) -> u32; fn size(&self) -> u64; fn mtime(&self) -> i64; }
                impl MetadataExt for Metadata {}
                pub fn symlink<P: AsRef<Path>, Q: AsRef<Path>>(original: P, link: Q) -> io::Result<()>;
            }
            pub mod ffi {
                pub trait OsStrExt { fn from_bytes(slice: &[u8]) -> &Self; fn as_bytes(&self) -> &[u8]; }
                impl OsStrExt for OsStr {}
                pub trait OsStringExt { fn from_vec(vec: Vec<u8>) -> Self; fn into_vec(self) -> Vec<u8>; }
                impl OsStringExt for OsString {}
            }
        }
    }

    pub mod panic {
        pub fn catch_unwind<F: FnOnce() -> R + UnwindSafe, R>(f: F) -> Result<R, Box<dyn Any + Send + 'static>>;
        pub fn resume_unwind(payload: Box<dyn Any + Send>) -> !; pub fn panic_any<M: 'static + Any + Send>(msg: M) -> !;
        pub fn set_hook(hook: Box<dyn Fn(&PanicHookInfo<'_>) + Sync + Send + 'static>); pub fn take_hook() -> Box<dyn Fn(&PanicHookInfo<'_>) + Sync + Send + 'static>;
        pub trait UnwindSafe {} pub trait RefUnwindSafe {}
        #[derive(Debug)] pub struct AssertUnwindSafe<T>(pub T);
        impl<T> Deref for AssertUnwindSafe<T> { type Target = T; }
        impl<F: Future> Future for AssertUnwindSafe<F> { type Output = F::Output; }
        #[derive(Clone, Copy, Debug, Display, PartialEq, Eq, PartialOrd, Ord, Hash)] pub struct Location<'a>;
        impl<'a> Location<'a> { pub fn caller() -> &'static Location<'static>; pub fn file(&self) -> &str; pub fn line(&self) -> u32; pub fn column(&self) -> u32; }
        #[derive(Debug, Display)] pub struct PanicHookInfo<'a>;
        impl<'a> PanicHookInfo<'a> { pub fn payload(&self) -> &(dyn Any + Send); pub fn location(&self) -> Option<&Location<'_>>; }
        pub type PanicInfo<'a> = PanicHookInfo<'a>;
    }

    pub mod hint {
        pub fn spin_loop(); pub fn black_box<T>(dummy: T) -> T; pub unsafe fn unreachable_unchecked() -> !; pub unsafe fn assert_unchecked(cond: bool);
    }

    pub mod alloc {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)] pub struct Layout;
        impl Layout {
            pub const fn new<T>() -> Self; pub fn for_value<T: ?Sized>(t: &T) -> Self; pub const fn from_size_align(size: usize, align: usize) -> Result<Self, LayoutError>;
            pub const unsafe fn from_size_align_unchecked(size: usize, align: usize) -> Self; pub const fn size(&self) -> usize; pub const fn align(&self) -> usize;
            pub fn array<T>(n: usize) -> Result<Self, LayoutError>;
        }
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct LayoutError;
        #[derive(Clone, Copy, Debug, Default)] pub struct Global;
        #[derive(Clone, Copy, Debug, Default)] pub struct System;
        pub unsafe fn alloc(layout: Layout) -> *mut u8; pub unsafe fn dealloc(ptr: *mut u8, layout: Layout); pub unsafe fn alloc_zeroed(layout: Layout) -> *mut u8;
        pub unsafe fn realloc(ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8; pub fn handle_alloc_error(layout: Layout) -> !;
        pub unsafe trait GlobalAlloc { unsafe fn alloc(&self, layout: Layout) -> *mut u8; unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout); }
    }

    pub mod ascii { pub trait AsciiExt {} pub fn escape_default(c: u8) -> EscapeDefault; pub struct EscapeDefault; }
    pub mod char { pub fn from_u32(i: u32) -> Option<char>; pub fn from_digit(num: u32, radix: u32) -> Option<char>; pub const MAX: char; pub const REPLACEMENT_CHARACTER: char; }
    pub mod slice {
        pub unsafe fn from_raw_parts<'a, T>(data: *const T, len: usize) -> &'a [T]; pub unsafe fn from_raw_parts_mut<'a, T>(data: *mut T, len: usize) -> &'a mut [T];
        pub fn from_ref<T>(s: &T) -> &[T];
        pub use crate::primitive::{Iter, IterMut, Chunks, Windows};
    }
    pub mod cmp_impls {}

    // What `use std::x::Y` names when std re-exports it from elsewhere.
    pub use crate::sync::atomic;
    pub use crate::collections::hash_map;

    pub mod prelude_v1 { pub use crate::prelude::*; }
    pub mod rust_2015 { pub use crate::prelude::*; } pub mod rust_2018 { pub use crate::prelude::*; } pub mod rust_2021 { pub use crate::prelude::*; } pub mod rust_2024 { pub use crate::prelude::*; }

    """#

  /// Every integer type's methods, from one template.
  private static var integers: String {
    var text = "pub mod integer_impls {\n"
    for (type, signed, bits) in [
      ("i8", true, 8), ("i16", true, 16), ("i32", true, 32), ("i64", true, 64), ("i128", true, 128), ("isize", true, 64),
      ("u8", false, 8), ("u16", false, 16), ("u32", false, 32), ("u64", false, 64), ("u128", false, 128), ("usize", false, 64),
    ] {
      let bytes = bits / 8
      text += """
            impl \(type) {
                pub const MIN: \(type); pub const MAX: \(type); pub const BITS: u32;
                pub const fn count_ones(self) -> u32; pub const fn count_zeros(self) -> u32; pub const fn leading_zeros(self) -> u32; pub const fn trailing_zeros(self) -> u32;
                pub const fn leading_ones(self) -> u32; pub const fn trailing_ones(self) -> u32; pub const fn rotate_left(self, n: u32) -> \(type); pub const fn rotate_right(self, n: u32) -> \(type);
                pub const fn swap_bytes(self) -> \(type); pub const fn reverse_bits(self) -> \(type); pub const fn from_be(x: \(type)) -> \(type); pub const fn from_le(x: \(type)) -> \(type);
                pub const fn to_be(self) -> \(type); pub const fn to_le(self) -> \(type);
                pub const fn checked_add(self, rhs: \(type)) -> Option<\(type)>; pub const fn checked_sub(self, rhs: \(type)) -> Option<\(type)>;
                pub const fn checked_mul(self, rhs: \(type)) -> Option<\(type)>; pub const fn checked_div(self, rhs: \(type)) -> Option<\(type)>;
                pub const fn checked_rem(self, rhs: \(type)) -> Option<\(type)>; pub const fn checked_shl(self, rhs: u32) -> Option<\(type)>; pub const fn checked_shr(self, rhs: u32) -> Option<\(type)>;
                pub const fn checked_pow(self, exp: u32) -> Option<\(type)>; pub const fn checked_neg(self) -> Option<\(type)>;
                pub const fn saturating_add(self, rhs: \(type)) -> \(type); pub const fn saturating_sub(self, rhs: \(type)) -> \(type); pub const fn saturating_mul(self, rhs: \(type)) -> \(type);
                pub const fn saturating_pow(self, exp: u32) -> \(type); pub const fn saturating_div(self, rhs: \(type)) -> \(type);
                pub const fn wrapping_add(self, rhs: \(type)) -> \(type); pub const fn wrapping_sub(self, rhs: \(type)) -> \(type); pub const fn wrapping_mul(self, rhs: \(type)) -> \(type);
                pub const fn wrapping_div(self, rhs: \(type)) -> \(type); pub const fn wrapping_rem(self, rhs: \(type)) -> \(type); pub const fn wrapping_neg(self) -> \(type);
                pub const fn wrapping_shl(self, rhs: u32) -> \(type); pub const fn wrapping_shr(self, rhs: u32) -> \(type); pub const fn wrapping_pow(self, exp: u32) -> \(type);
                pub const fn overflowing_add(self, rhs: \(type)) -> (\(type), bool); pub const fn overflowing_sub(self, rhs: \(type)) -> (\(type), bool);
                pub const fn overflowing_mul(self, rhs: \(type)) -> (\(type), bool); pub const fn pow(self, exp: u32) -> \(type);
                pub const fn div_euclid(self, rhs: \(type)) -> \(type); pub const fn rem_euclid(self, rhs: \(type)) -> \(type); pub const fn div_ceil(self, rhs: \(type)) -> \(type);
                pub const fn ilog2(self) -> u32; pub const fn ilog10(self) -> u32; pub const fn isqrt(self) -> \(type); pub const fn midpoint(self, rhs: \(type)) -> \(type);
                pub const fn to_be_bytes(self) -> [u8; \(bytes)]; pub const fn to_le_bytes(self) -> [u8; \(bytes)]; pub const fn to_ne_bytes(self) -> [u8; \(bytes)];
                pub const fn from_be_bytes(bytes: [u8; \(bytes)]) -> \(type); pub const fn from_le_bytes(bytes: [u8; \(bytes)]) -> \(type); pub const fn from_ne_bytes(bytes: [u8; \(bytes)]) -> \(type);
                pub fn from_str_radix(src: &str, radix: u32) -> Result<\(type), ParseIntError>;

        """
      if signed {
        text += """
                  pub const fn abs(self) -> \(type); pub const fn signum(self) -> \(type); pub const fn is_positive(self) -> bool; pub const fn is_negative(self) -> bool;
                  pub const fn unsigned_abs(self) -> u\(type.dropFirst()); pub const fn abs_diff(self, other: \(type)) -> u\(type.dropFirst()); pub const fn checked_abs(self) -> Option<\(type)>;
                  pub const fn wrapping_abs(self) -> \(type); pub const fn saturating_neg(self) -> \(type); pub const fn saturating_abs(self) -> \(type);

          """
      } else {
        text += """
                  pub const fn is_power_of_two(self) -> bool; pub const fn next_power_of_two(self) -> \(type); pub const fn checked_next_power_of_two(self) -> Option<\(type)>;
                  pub const fn abs_diff(self, other: \(type)) -> \(type); pub const fn checked_add_signed(self, rhs: i\(type.dropFirst())) -> Option<\(type)>;
                  pub const fn saturating_add_signed(self, rhs: i\(type.dropFirst())) -> \(type); pub const fn wrapping_add_signed(self, rhs: i\(type.dropFirst())) -> \(type);
                  pub const fn is_multiple_of(self, rhs: \(type)) -> bool; pub const fn next_multiple_of(self, rhs: \(type)) -> \(type);

          """
      }
      if type == "u8" {
        text += """
                  pub const fn is_ascii(&self) -> bool; pub const fn is_ascii_digit(&self) -> bool; pub const fn is_ascii_alphabetic(&self) -> bool;
                  pub const fn is_ascii_alphanumeric(&self) -> bool; pub const fn is_ascii_whitespace(&self) -> bool; pub const fn is_ascii_uppercase(&self) -> bool;
                  pub const fn is_ascii_lowercase(&self) -> bool; pub const fn is_ascii_hexdigit(&self) -> bool; pub const fn is_ascii_punctuation(&self) -> bool;
                  pub const fn is_ascii_graphic(&self) -> bool; pub const fn is_ascii_control(&self) -> bool; pub const fn to_ascii_lowercase(&self) -> u8;
                  pub const fn to_ascii_uppercase(&self) -> u8; pub const fn eq_ignore_ascii_case(&self, other: &u8) -> bool; pub fn make_ascii_lowercase(&mut self);

          """
      }
      text += "    }\n"
      for op in ["Add", "Sub", "Mul", "Div", "Rem", "BitAnd", "BitOr", "BitXor", "Shl", "Shr"] {
        text += "    impl \(op) for \(type) { type Output = \(type); }\n"
      }
      text += "    impl FromStr for \(type) { type Err = ParseIntError; }\n"
    }
    return text + "}\n\n"
  }

  private static let floats = #"""
    pub mod float_impls {
        impl f64 {
            pub const EPSILON: f64; pub const MIN: f64; pub const MAX: f64; pub const MIN_POSITIVE: f64; pub const NAN: f64; pub const INFINITY: f64; pub const NEG_INFINITY: f64;
            pub fn abs(self) -> f64; pub fn sqrt(self) -> f64; pub fn floor(self) -> f64; pub fn ceil(self) -> f64; pub fn round(self) -> f64; pub fn trunc(self) -> f64;
            pub fn fract(self) -> f64; pub fn powi(self, n: i32) -> f64; pub fn powf(self, n: f64) -> f64; pub fn exp(self) -> f64; pub fn ln(self) -> f64; pub fn log10(self) -> f64;
            pub fn log2(self) -> f64; pub fn sin(self) -> f64; pub fn cos(self) -> f64; pub fn tan(self) -> f64; pub fn atan2(self, other: f64) -> f64; pub fn hypot(self, other: f64) -> f64;
            pub fn min(self, other: f64) -> f64; pub fn max(self, other: f64) -> f64; pub fn clamp(self, min: f64, max: f64) -> f64; pub fn signum(self) -> f64;
            pub const fn is_nan(self) -> bool; pub const fn is_finite(self) -> bool; pub const fn is_infinite(self) -> bool; pub const fn is_sign_negative(self) -> bool;
            pub const fn to_bits(self) -> u64; pub const fn from_bits(v: u64) -> f64; pub fn total_cmp(&self, other: &f64) -> Ordering; pub fn mul_add(self, a: f64, b: f64) -> f64;
            pub fn to_be_bytes(self) -> [u8; 8]; pub fn to_le_bytes(self) -> [u8; 8]; pub fn from_be_bytes(bytes: [u8; 8]) -> f64; pub fn from_le_bytes(bytes: [u8; 8]) -> f64;
        }
        impl f32 {
            pub const EPSILON: f32; pub const MIN: f32; pub const MAX: f32; pub const NAN: f32; pub const INFINITY: f32;
            pub fn abs(self) -> f32; pub fn sqrt(self) -> f32; pub fn floor(self) -> f32; pub fn ceil(self) -> f32; pub fn round(self) -> f32; pub fn powi(self, n: i32) -> f32;
            pub fn powf(self, n: f32) -> f32; pub fn min(self, other: f32) -> f32; pub fn max(self, other: f32) -> f32; pub fn clamp(self, min: f32, max: f32) -> f32;
            pub const fn is_nan(self) -> bool; pub const fn is_finite(self) -> bool; pub const fn to_bits(self) -> u32; pub const fn from_bits(v: u32) -> f32;
        }
        impl Add for f64 { type Output = f64; } impl Sub for f64 { type Output = f64; } impl Mul for f64 { type Output = f64; } impl Div for f64 { type Output = f64; }
        impl Add for f32 { type Output = f32; } impl Sub for f32 { type Output = f32; } impl Mul for f32 { type Output = f32; } impl Div for f32 { type Output = f32; }
        impl FromStr for f64 { type Err = ParseFloatError; } impl FromStr for f32 { type Err = ParseFloatError; } impl FromStr for bool { type Err = ParseBoolError; }
        #[derive(Clone, Debug, Display, PartialEq, Eq)] pub struct ParseBoolError;
    }

    """#

  private static let macros = #"""
    #[macro_export] macro_rules! println { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! print { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! eprintln { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! eprint { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! format { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! format_args { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! write { ($dst:expr, $($arg:tt)*) => {}; }
    #[macro_export] macro_rules! writeln { ($dst:expr $(,)?) => {}; ($dst:expr, $($arg:tt)*) => {}; }
    #[macro_export] macro_rules! vec { () => {}; ($elem:expr; $n:expr) => {}; ($($x:expr),+ $(,)?) => {}; }
    #[macro_export] macro_rules! panic { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! assert { ($cond:expr $(,)?) => {}; ($cond:expr, $($arg:tt)+) => {}; }
    #[macro_export] macro_rules! assert_eq { ($left:expr, $right:expr $(,)?) => {}; ($left:expr, $right:expr, $($arg:tt)+) => {}; }
    #[macro_export] macro_rules! assert_ne { ($left:expr, $right:expr $(,)?) => {}; ($left:expr, $right:expr, $($arg:tt)+) => {}; }
    #[macro_export] macro_rules! debug_assert { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! debug_assert_eq { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! debug_assert_ne { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! unreachable { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! todo { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! unimplemented { ($($arg:tt)*) => {}; }
    #[macro_export] macro_rules! matches { ($expression:expr, $pattern:pat $(if $guard:expr)? $(,)?) => {}; }
    #[macro_export] macro_rules! dbg { ($($val:expr),* $(,)?) => {}; }
    #[macro_export] macro_rules! thread_local { ($($t:tt)*) => {}; }
    #[macro_export] macro_rules! ready { ($e:expr $(,)?) => {}; }
    #[macro_export] macro_rules! addr_of { ($place:expr) => {}; }
    #[macro_export] macro_rules! addr_of_mut { ($place:expr) => {}; }
    #[macro_export] macro_rules! cfg { ($($cfg:tt)*) => {}; }
    #[macro_export] macro_rules! concat { ($($e:expr),* $(,)?) => {}; }
    #[macro_export] macro_rules! stringify { ($($t:tt)*) => {}; }
    #[macro_export] macro_rules! env { ($name:expr $(,)?) => {}; }
    #[macro_export] macro_rules! option_env { ($name:expr $(,)?) => {}; }
    #[macro_export] macro_rules! include_str { ($file:expr $(,)?) => {}; }
    #[macro_export] macro_rules! include_bytes { ($file:expr $(,)?) => {}; }
    #[macro_export] macro_rules! include { ($file:expr $(,)?) => {}; }
    #[macro_export] macro_rules! line { () => {}; }
    #[macro_export] macro_rules! column { () => {}; }
    #[macro_export] macro_rules! file { () => {}; }
    #[macro_export] macro_rules! module_path { () => {}; }
    #[macro_export] macro_rules! compile_error { ($msg:expr $(,)?) => {}; }
    #[macro_export] macro_rules! pin { ($value:expr $(,)?) => {}; }
    #[macro_export] macro_rules! try { ($e:expr $(,)?) => {}; }

    """#
}
