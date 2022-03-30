//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftShims

//
// StringGuts is a parameterization over String's representations. It provides
// functionality and guidance for efficiently working with Strings.
//
@frozen
public // SPI(corelibs-foundation)
struct _StringGuts: @unchecked Sendable {
  @usableFromInline
  internal var _object: _StringObject

  @inlinable @inline(__always)
  internal init(_ object: _StringObject) {
    self._object = object
    _invariantCheck()
  }

  // Empty string
  @inlinable @inline(__always)
  init() {
    self.init(_StringObject(empty: ()))
  }
}

// Raw
extension _StringGuts {
  @inlinable @inline(__always)
  internal var rawBits: _StringObject.RawBitPattern {
    return _object.rawBits
  }
}

// Creation
extension _StringGuts {
  @inlinable @inline(__always)
  internal init(_ smol: _SmallString) {
    self.init(_StringObject(smol))
  }

  @inlinable @inline(__always)
  internal init(_ bufPtr: UnsafeBufferPointer<UInt8>, isASCII: Bool) {
    self.init(_StringObject(immortal: bufPtr, isASCII: isASCII))
  }

  @inline(__always)
  internal init(_ storage: __StringStorage) {
    self.init(_StringObject(storage))
  }

  internal init(_ storage: __SharedStringStorage) {
    self.init(_StringObject(storage))
  }

  internal init(
    cocoa: AnyObject, providesFastUTF8: Bool, isASCII: Bool, length: Int
  ) {
    self.init(_StringObject(
      cocoa: cocoa,
      providesFastUTF8: providesFastUTF8,
      isASCII: isASCII,
      length: length))
  }
}

// Queries
extension _StringGuts {
  // The number of code units
  @inlinable @inline(__always)
  internal var count: Int { return _object.count }

  @inlinable @inline(__always)
  internal var isEmpty: Bool { return count == 0 }

  @inlinable @inline(__always)
  internal var isSmall: Bool { return _object.isSmall }

  @inline(__always)
  internal var isSmallASCII: Bool {
    return _object.isSmall && _object.smallIsASCII
  }

  @inlinable @inline(__always)
  internal var asSmall: _SmallString {
    return _SmallString(_object)
  }

  @inlinable @inline(__always)
  internal var isASCII: Bool  {
    return _object.isASCII
  }

  @inlinable @inline(__always)
  internal var isFastASCII: Bool  {
    return isFastUTF8 && _object.isASCII
  }

  @inline(__always)
  internal var isNFC: Bool { return _object.isNFC }

  @inline(__always)
  internal var isNFCFastUTF8: Bool {
    // TODO(String micro-performance): Consider a dedicated bit for this
    return _object.isNFC && isFastUTF8
  }

  internal var hasNativeStorage: Bool { return _object.hasNativeStorage }

  internal var hasSharedStorage: Bool { return _object.hasSharedStorage }

  // Whether this string has breadcrumbs
  internal var hasBreadcrumbs: Bool {
    return hasSharedStorage
      || (hasNativeStorage && _object.nativeStorage.hasBreadcrumbs)
  }
}

//
extension _StringGuts {
  // Whether we can provide fast access to contiguous UTF-8 code units
  @_transparent
  @inlinable
  internal var isFastUTF8: Bool { return _fastPath(_object.providesFastUTF8) }

  // A String which does not provide fast access to contiguous UTF-8 code units
  @inlinable @inline(__always)
  internal var isForeign: Bool {
     return _slowPath(_object.isForeign)
  }

  @inlinable @inline(__always)
  internal func withFastUTF8<R>(
    _ f: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R {
    _internalInvariant(isFastUTF8)

    if self.isSmall { return try _SmallString(_object).withUTF8(f) }

    defer { _fixLifetime(self) }
    return try f(_object.fastUTF8)
  }

  @inlinable @inline(__always)
  internal func withFastUTF8<R>(
    range: Range<Int>,
    _ f: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R {
    return try self.withFastUTF8 { wholeUTF8 in
      return try f(UnsafeBufferPointer(rebasing: wholeUTF8[range]))
    }
  }

  @inlinable @inline(__always)
  internal func withFastCChar<R>(
    _ f: (UnsafeBufferPointer<CChar>) throws -> R
  ) rethrows -> R {
    return try self.withFastUTF8 { utf8 in
      let ptr = utf8.baseAddress._unsafelyUnwrappedUnchecked._asCChar
      return try f(UnsafeBufferPointer(start: ptr, count: utf8.count))
    }
  }
}

// Internal invariants
extension _StringGuts {
  #if !INTERNAL_CHECKS_ENABLED
  @inlinable @inline(__always) internal func _invariantCheck() {}
  #else
  @usableFromInline @inline(never) @_effects(releasenone)
  internal func _invariantCheck() {
    #if arch(i386) || arch(arm) || arch(arm64_32) || arch(wasm32)
    _internalInvariant(MemoryLayout<String>.size == 12, """
    the runtime is depending on this, update Reflection.mm and \
    this if you change it
    """)
    #else
    _internalInvariant(MemoryLayout<String>.size == 16, """
    the runtime is depending on this, update Reflection.mm and \
    this if you change it
    """)
    #endif
  }
  #endif // INTERNAL_CHECKS_ENABLED

  internal func _dump() { _object._dump() }
}

// C String interop
extension _StringGuts {
  @inlinable @inline(__always) // fast-path: already C-string compatible
  internal func withCString<Result>(
    _ body: (UnsafePointer<Int8>) throws -> Result
  ) rethrows -> Result {
    if _slowPath(!_object.isFastZeroTerminated) {
      return try _slowWithCString(body)
    }

    return try self.withFastCChar {
      return try body($0.baseAddress._unsafelyUnwrappedUnchecked)
    }
  }

  @inline(never) // slow-path
  @usableFromInline
  internal func _slowWithCString<Result>(
    _ body: (UnsafePointer<Int8>) throws -> Result
  ) rethrows -> Result {
    _internalInvariant(!_object.isFastZeroTerminated)
    return try String(self).utf8CString.withUnsafeBufferPointer {
      let ptr = $0.baseAddress._unsafelyUnwrappedUnchecked
      return try body(ptr)
    }
  }
}

extension _StringGuts {
  // Copy UTF-8 contents. Returns number written or nil if not enough space.
  // Contents of the buffer are unspecified if nil is returned.
  @inlinable
  internal func copyUTF8(into mbp: UnsafeMutableBufferPointer<UInt8>) -> Int? {
    let ptr = mbp.baseAddress._unsafelyUnwrappedUnchecked
    if _fastPath(self.isFastUTF8) {
      return self.withFastUTF8 { utf8 in
        guard utf8.count <= mbp.count else { return nil }

        let utf8Start = utf8.baseAddress._unsafelyUnwrappedUnchecked
        ptr.initialize(from: utf8Start, count: utf8.count)
        return utf8.count
      }
    }

    return _foreignCopyUTF8(into: mbp)
  }
  @_effects(releasenone)
  @usableFromInline @inline(never) // slow-path
  internal func _foreignCopyUTF8(
    into mbp: UnsafeMutableBufferPointer<UInt8>
  ) -> Int? {
    #if _runtime(_ObjC)
    // Currently, foreign  means NSString
    if let res = _cocoaStringCopyUTF8(_object.cocoaObject,
      into: UnsafeMutableRawBufferPointer(start: mbp.baseAddress,
                                          count: mbp.count)) {
      return res
    }
    
    // If the NSString contains invalid UTF8 (e.g. unpaired surrogates), we
    // can get nil from cocoaStringCopyUTF8 in situations where a character by
    // character loop would get something more useful like repaired contents
    var ptr = mbp.baseAddress._unsafelyUnwrappedUnchecked
    var numWritten = 0
    for cu in String(self).utf8 {
      guard numWritten < mbp.count else { return nil }
      ptr.initialize(to: cu)
      ptr += 1
      numWritten += 1
    }
    
    return numWritten
    #else
    fatalError("No foreign strings on Linux in this version of Swift")
    #endif
  }

  @inline(__always)
  internal var utf8Count: Int {
    if _fastPath(self.isFastUTF8) { return count }
    return String(self).utf8.count
  }
}

// Index
extension _StringGuts {
  @usableFromInline
  internal typealias Index = String.Index

  @inlinable @inline(__always)
  internal var startIndex: String.Index {
    // The start index is always `Character` aligned.
    Index(_encodedOffset: 0)._characterAligned._encodingIndependent
  }

  @inlinable @inline(__always)
  internal var endIndex: String.Index {
    // The end index is always `Character` aligned.
    markEncoding(Index(_encodedOffset: self.count)._characterAligned)
  }
}

@_alwaysEmitIntoClient
@inline(__always)
func _isSwiftStdlib_5_7() -> Bool {
  if #available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *) { // SwiftStdlib 5.7
    return true
  } else {
    return false
  }
}

// Encoding
extension _StringGuts {
  /// Returns whether this string is known to use UTF-16 code units.
  ///
  /// This always returns a value corresponding to the string's actual encoding
  /// on stdlib versions >=5.7.
  ///
  /// Standard Library versions <=5.6 did not set the corresponding flag, so
  /// this property always returns false.
  @_alwaysEmitIntoClient
  @inline(__always)
  internal var isKnownUTF16: Bool { _object.isKnownUTF16 }

  @_alwaysEmitIntoClient // Swift 5.7
  internal func markEncoding(_ i: String.Index) -> String.Index {
    // In this inlinable function, we cannot assume that all foreign strings are
    // UTF-16 encoded, as this code may run on a future stdlib that may have
    // introduced other foreign forms.
    if #available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *) { // SwiftStdlib 5.7
      // With a >=5.7 stdlib, we can rely on `isKnownUTF16` to contain the truth.
      return isKnownUTF16 ? i._knownUTF16 : i._knownUTF8
    }
    // We know that in stdlibs 5.0..<5.7, all foreign strings were UTF-16,
    // so we can use `isForeign` to determine the encoding.
    return isForeign ? i._knownUTF16 : i._knownUTF8
  }

  @inline(__always)
  internal func internalMarkEncoding(_ i: String.Index) -> String.Index {
    // This code is behind a resiliance boundary, so it always runs on a >=5.7
    // stdlib. Note though that it doesn't match the 5.7+ case in the inlinable
    // version above!
    //
    // We know that in this version of the stdlib, foreign strings happen to
    // always be UTF-16 encoded (like they were between 5.0 and 5.6), and
    // looking at `isForeign` instead of `isKnownUTF16` may allow the stdlib's
    // internal code to be better optimized -- so let's do that.
    isForeign ? i._knownUTF16 : i._knownUTF8
  }

  /// Returns true if the encoding of the given index isn't known to be in
  /// conflict with this string's encoding.
  ///
  /// If the index or the string was created by code that was built on stdlibs
  /// below 5.7, then this check may incorrectly return true on a mismatching
  /// index, but it is guaranteed to never incorrectly return false. If all
  /// loaded binaries were built in 5.7+, then this method is guaranteed to
  /// always return the correct value.
  internal func hasMatchingEncoding(_ i: String.Index) -> Bool {
    (isForeign && i._canBeUTF16) || (!isForeign && i._canBeUTF8)
  }

  /// Return an index whose encoding can be assumed to match that of `self`.
  ///
  /// Detecting an encoding mismatch isn't always possible -- older binaries did
  /// not set the flags that this method relies on. However, false positives
  /// cannot happen: if this method detects a mismatch, then it is guaranteed to
  /// be a real one.
  @_alwaysEmitIntoClient
  @inline(__always)
  internal func ensureMatchingEncoding(_ i: String.Index) -> String.Index {
    if _fastPath(!isForeign && i._canBeUTF8) { return i }
    return _slowEnsureMatchingEncoding(i)
  }

  @_alwaysEmitIntoClient
  @inline(never)
  internal func _slowEnsureMatchingEncoding(_ i: String.Index) -> String.Index {
    _internalInvariant(isForeign || !i._canBeUTF8)
    if isForeign {
      // Opportunistically detect attempts to use an UTF-8 index on a UTF-16
      // string. Strings don't usually get converted to UTF-16 storage, so it
      // seems okay to trap in this case -- the index most likely comes from an
      // unrelated string. (Trapping here may still turn out to affect binary
      // compatibility with broken code in existing binaries running with new
      // stdlibs. If so, we can replace this with the same transcoding hack as
      // in the UTF-16->8 case below.)
      //
      // Note that this trap is not guaranteed to trigger when the process
      // includes client binaries compiled with a previous Swift release.
      // (`i._canBeUTF16` can sometimes return true in that case even if the
      // index actually came from an UTF-8 string.) However, the trap will still
      // often trigger in this case, as long as the index was initialized by
      // code that was compiled with 5.7+.
      //
      // This trap can never trigger on OSes that have stdlibs <= 5.6, because
      // those versions never set the `isKnownUTF16` flag in `_StringObject`.
      //
      _precondition(!isKnownUTF16 || i._canBeUTF16,
        "Invalid string index")
      return i
    }
    // If we get here, then we know for sure that this is an attempt to use an
    // UTF-16 index on a UTF-8 string.
    //
    // This can happen if `self` was originally verbatim-bridged, and someone
    // mistakenly attempts to keep using an old index after a mutation. This is
    // technically an error, but trapping here would trigger a lot of broken
    // code that previously happened to work "fine" on e.g. ASCII strings.
    // Instead, attempt to convert the offset to UTF-8 code units by transcoding
    // the string. This can be slow, but it often results in a usable index,
    // even if non-ASCII characters are present. (UTF-16 breadcrumbs help reduce
    // the severity of the slowdown.)

    // FIXME: Consider emitting a runtime warning here.
    // FIXME: Consider performing a linked-on-or-after check & trapping if the
    // client executable was built on some particular future Swift release.
    let utf16 = String(self).utf16
    return utf16.index(utf16.startIndex, offsetBy: i._encodedOffset)
  }
}

// Index validation
extension _StringGuts {
  /// Validate `i` and adjust its position toward the start, returning the
  /// resulting index or trapping as appropriate. If this function returns, then
  /// the returned value
  ///
  /// - has an encoding that matches this string,
  /// - is within the bounds of this string, and
  /// - is aligned on a scalar boundary.
  @_alwaysEmitIntoClient
  internal func validateScalarIndex(_ i: String.Index) -> String.Index {
    let i = ensureMatchingEncoding(i)
    _precondition(i._encodedOffset < count, "String index is out of bounds")
    return scalarAlign(i)
  }

  /// Validate `i` and adjust its position toward the start, returning the
  /// resulting index or trapping as appropriate. If this function returns, then
  /// the returned value
  ///
  /// - has an encoding that matches this string,
  /// - is within `start ..< end`, and
  /// - is aligned on a scalar boundary.
  @_alwaysEmitIntoClient
  internal func validateScalarIndex(
    _ i: String.Index,
    from start: String.Index,
    to end: String.Index
  ) -> String.Index {
    _internalInvariant(start <= end && end <= endIndex)

    let i = ensureMatchingEncoding(i)
    _precondition(i >= start && i < end, "Substring index is out of bounds")
    return scalarAlign(i)
  }
}

extension _StringGuts {
  /// Validate `i` and adjust its position toward the start, returning the
  /// resulting index or trapping as appropriate. If this function returns, then
  /// the returned value
  ///
  /// - has an encoding that matches this string,
  /// - is within the bounds of this string (including the `endIndex`), and
  /// - is aligned on a scalar boundary.
  @_alwaysEmitIntoClient
  internal func validateInclusiveScalarIndex(
    _ i: String.Index
  ) -> String.Index {
    let i = ensureMatchingEncoding(i)
    _precondition(i._encodedOffset <= count, "String index is out of bounds")
    return scalarAlign(i)
  }

  /// Validate `i` and adjust its position toward the start, returning the
  /// resulting index or trapping as appropriate. If this function returns, then
  /// the returned value
  ///
  /// - has an encoding that matches this string,
  /// - is within the bounds of this string (including the `endIndex`), and
  /// - is aligned on a scalar boundary.
  internal func validateInclusiveScalarIndex(
    _ i: String.Index,
    from start: String.Index,
    to end: String.Index
  ) -> String.Index {
    _internalInvariant(start <= end && end <= endIndex)

    let i = ensureMatchingEncoding(i)
    _precondition(i >= start && i <= end, "Substring index is out of bounds")
    return scalarAlign(i)
  }
}

extension _StringGuts {
  @_alwaysEmitIntoClient
  internal func validateSubscalarRange(
    _ range: Range<String.Index>
  ) -> Range<String.Index> {
    let upper = ensureMatchingEncoding(range.upperBound)
    let lower = ensureMatchingEncoding(range.lowerBound)

    // Note: if only `lower` was miscoded, then the range invariant `lower <=
    // upper` may no longer hold after the above conversions, so we need to
    // re-check it here.
    _precondition(upper._encodedOffset <= count && lower <= upper,
      "String index range is out of bounds")

    return Range(_uncheckedBounds: (lower, upper))
  }

  @_alwaysEmitIntoClient
  internal func validateSubscalarRange(
    _ range: Range<String.Index>,
    from start: String.Index,
    to end: String.Index
  ) -> Range<String.Index> {
    _internalInvariant(start <= end && end <= endIndex)

    let upper = ensureMatchingEncoding(range.upperBound)
    let lower = ensureMatchingEncoding(range.lowerBound)

    // Note: if only `lower` was miscoded, then the range invariant `lower <=
    // upper` may no longer hold after the above conversions, so we need to
    // re-check it here.
    _precondition(upper <= end && lower >= start && lower <= upper,
      "Substring index range is out of bounds")

    return Range(_uncheckedBounds: (lower, upper))
  }
}

extension _StringGuts {
  /// Validate `range` and adjust the position of its bounds, returning the
  /// resulting range or trapping as appropriate. If this function returns, then
  /// the bounds of the returned value
  ///
  /// - have an encoding that matches this string,
  /// - are within the bounds of this string, and
  /// - are aligned on a scalar boundary.
  internal func validateScalarRange(
    _ range: Range<String.Index>
  ) -> Range<String.Index> {
    var upper = ensureMatchingEncoding(range.upperBound)
    var lower = ensureMatchingEncoding(range.lowerBound)

    // Note: if only `lower` was miscoded, then the range invariant `lower <=
    // upper` may no longer hold after the above conversions, so we need to
    // re-check it here.
    _precondition(upper._encodedOffset <= count && lower <= upper,
      "String index range is out of bounds")

    upper = scalarAlign(upper)
    lower = scalarAlign(lower)

    // Older binaries may generate `startIndex` without the
    // `_isCharacterAligned` flag. Compensate for that here so that substrings
    // that start at the beginning will never get the sad path in
    // `index(after:)`. Note that we don't need to do this for `upper` and we
    // don't need to compare against the `endIndex` -- those aren't nearly as
    // critical.
    if lower._encodedOffset == 0 { lower = lower._characterAligned }

    return Range(_uncheckedBounds: (lower, upper))
  }

  /// Validate `range` and adjust the position of its bounds, returning the
  /// resulting range or trapping as appropriate. If this function returns, then
  /// the bounds of the returned value
  ///
  /// - have an encoding that matches this string,
  /// - are within `start ..< end`, and
  /// - are aligned on a scalar boundary.
  internal func validateScalarRange(
    _ range: Range<String.Index>,
    from start: String.Index,
    to end: String.Index
  ) -> Range<String.Index> {
    _internalInvariant(start <= end && end <= endIndex)

    var upper = ensureMatchingEncoding(range.upperBound)
    var lower = ensureMatchingEncoding(range.lowerBound)

    // Note: if only `lower` was miscoded, then the range invariant `lower <=
    // upper` may no longer hold after the above conversions, so we need to
    // re-check it here.
    _precondition(upper <= end && lower >= start && lower <= upper,
      "Substring index range is out of bounds")

    upper = scalarAlign(upper)
    lower = scalarAlign(lower)

    return Range(_uncheckedBounds: (lower, upper))
  }
}

// Old SPI(corelibs-foundation)
extension _StringGuts {
  @available(*, deprecated)
  public // SPI(corelibs-foundation)
  var _isContiguousASCII: Bool {
    return !isSmall && isFastUTF8 && isASCII
  }

  @available(*, deprecated)
  public // SPI(corelibs-foundation)
  var _isContiguousUTF16: Bool {
    return false
  }

  // FIXME: Remove. Still used by swift-corelibs-foundation
  @available(*, deprecated)
  public var startASCII: UnsafeMutablePointer<UInt8> {
    return UnsafeMutablePointer(mutating: _object.fastUTF8.baseAddress!)
  }

  // FIXME: Remove. Still used by swift-corelibs-foundation
  @available(*, deprecated)
  public var startUTF16: UnsafeMutablePointer<UTF16.CodeUnit> {
    fatalError("Not contiguous UTF-16")
  }
}

@available(*, deprecated)
public // SPI(corelibs-foundation)
func _persistCString(_ p: UnsafePointer<CChar>?) -> [CChar]? {
  guard let s = p else { return nil }
  let bytesToCopy = UTF8._nullCodeUnitOffset(in: s) + 1 // +1 for the terminating NUL
  let result = [CChar](unsafeUninitializedCapacity: bytesToCopy) { buf, initedCount in
    buf.baseAddress!.assign(from: s, count: bytesToCopy)
    initedCount = bytesToCopy
  }
  return result
}

