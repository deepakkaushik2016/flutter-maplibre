import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/darwin/pending_presents.dart';

void main() {
  group('PendingPresents', () {
    test('settles a present once, with its value', () {
      final presents = PendingPresents<String>(4)..add(1, 7, 'frame 7');
      expect(presents.settle(1, 7), 'frame 7');
      expect(presents.settle(1, 7), isNull);
    });

    test('a late settle of an older present leaves the newer one', () {
      final presents = PendingPresents<String>(4)
        ..add(2, 3, 'frame 3')
        ..add(2, 5, 'frame 5');
      expect(presents.settle(2, 3), isNull);
      expect(presents.settle(2, 5), 'frame 5');
    });

    test('a settle of another slot leaves the present', () {
      final presents = PendingPresents<String>(4)..add(0, 9, 'frame 9');
      expect(presents.settle(1, 9), isNull);
      expect(presents.settle(0, 9), 'frame 9');
    });

    test('nothing settles after clear', () {
      final presents = PendingPresents<String>(4)
        ..add(0, 1, 'frame 1')
        ..add(3, 2, 'frame 2')
        ..clear();
      expect(presents.settle(0, 1), isNull);
      expect(presents.settle(3, 2), isNull);
    });

    test('a slot outside the ring settles nothing', () {
      final presents = PendingPresents<String>(4);
      expect(presents.settle(4, 1), isNull);
      expect(presents.settle(-1, 1), isNull);
    });
  });
}
