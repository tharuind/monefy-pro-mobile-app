import 'package:flutter_test/flutter_test.dart';
import 'package:mymoney/main.dart';

void main() {
  test('formats money in LKR, retaining cents', () {
    expect(money(123456), 'LKR 1,234.56');
    expect(money(0), 'LKR 0.00');
    expect(money(-50), '-LKR 0.50');
  });
}
