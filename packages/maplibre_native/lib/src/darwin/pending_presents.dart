/// The presents of a texture ring whose frames Flutter doesn't show yet, by
/// slot, each with the number the plugin gave it and a value of its own.
///
/// A slot holds one present at a time. The plugin settles each present with
/// its slot and number, so a settle that arrives after the slot moved on to a
/// newer present, or after [clear], finds nothing.
final class PendingPresents<T extends Object> {
  /// Creates the table of a ring of [slotCount] slots.
  PendingPresents(int slotCount)
    : _presents = List.filled(slotCount, 0),
      _values = List.filled(slotCount, null);

  final List<int> _presents;
  final List<T?> _values;

  /// Records the present numbered [present] in [slot], with [value].
  void add(int slot, int present, T value) {
    _presents[slot] = present;
    _values[slot] = value;
  }

  /// Takes the value of the present numbered [present] in [slot], or null
  /// when the slot holds another present or none.
  T? settle(int slot, int present) {
    if (slot < 0 || slot >= _presents.length || _presents[slot] != present) {
      return null;
    }
    final value = _values[slot];
    _presents[slot] = 0;
    _values[slot] = null;
    return value;
  }

  /// Forgets every present, such as when the ring was replaced.
  void clear() {
    _presents.fillRange(0, _presents.length, 0);
    _values.fillRange(0, _values.length, null);
  }
}
