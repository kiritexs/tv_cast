/// An inclusive byte range of a file of [size] bytes.
class ByteRange {
  const ByteRange(this.start, this.end, this.size);

  final int start;
  final int end;
  final int size;

  int get length => end - start + 1;

  /// The `Content-Range` header for it.
  String get contentRange => 'bytes $start-$end/$size';

  @override
  bool operator ==(Object other) =>
      other is ByteRange &&
      other.start == start &&
      other.end == end &&
      other.size == size;

  @override
  int get hashCode => Object.hash(start, end, size);

  @override
  String toString() => 'ByteRange($start-$end/$size)';
}

/// The range a `Range` header asks of a [size]-byte file: null without one
/// (the whole file), [RangeNotSatisfiable] when it lies past the end. Only
/// the first of several ranges is served.
ByteRange? parseRange(String? header, int size) {
  if (header == null || header.trim().isEmpty) return null;
  final m = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)').firstMatch(header);
  if (m == null) return null;
  final from = m[1]!, to = m[2]!;
  if (from.isEmpty && to.isEmpty) return null;
  // Digits past what an int holds read as "more than the file": never a
  // FormatException, which the relay would answer as a 502.
  if (from.isEmpty) {
    // The last N bytes.
    final n = int.tryParse(to) ?? size;
    if (n == 0 || size == 0) throw const RangeNotSatisfiable();
    final start = n >= size ? 0 : size - n;
    return ByteRange(start, size - 1, size);
  }
  final start = int.tryParse(from);
  if (start == null || start >= size) throw const RangeNotSatisfiable();
  final end = to.isEmpty ? size - 1 : int.tryParse(to) ?? size - 1;
  if (end < start) return null;
  return ByteRange(start, end >= size ? size - 1 : end, size);
}

/// A range starting past the end of the file: `416`.
class RangeNotSatisfiable implements Exception {
  const RangeNotSatisfiable();
}
