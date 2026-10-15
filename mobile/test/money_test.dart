import 'package:flutter_test/flutter_test.dart';
import 'package:kaha_pos/core/money.dart';

void main() {
  test('parses peso text into centavos without floats', () {
    expect(parsePeso('85'), 8500);
    expect(parsePeso('85.5'), 8550);
    expect(parsePeso('₱1,234.05'), 123405);
    expect(parsePeso('0.25'), 25);
    expect(parsePeso('12.345'), isNull);
    expect(parsePeso('abc'), isNull);
    expect(parsePeso(''), isNull);
  });

  test('formats centavos', () {
    expect(formatPeso(0), '₱0.00');
    expect(formatPeso(17180), '₱171.80');
    expect(formatPeso(123456789), '₱1,234,567.89');
    expect(formatPeso(-500), '−₱5.00');
    expect(pesoInputText(18500), '185.00');
  });
}
