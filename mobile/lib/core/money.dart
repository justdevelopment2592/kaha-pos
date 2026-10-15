/// Money is always whole centavos (int). Never use double for money.
String formatPeso(int centavos) {
  final negative = centavos < 0;
  final abs = centavos.abs();
  final pesos = (abs ~/ 100).toString();
  final cents = (abs % 100).toString().padLeft(2, '0');
  final grouped = StringBuffer();
  for (var i = 0; i < pesos.length; i++) {
    final fromEnd = pesos.length - i;
    grouped.write(pesos[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) grouped.write(',');
  }
  return '${negative ? '−' : ''}₱$grouped.$cents';
}

/// Parses "1,234.5", "₱99", "0.25" into centavos without floating point.
/// Returns null when the text is not a valid amount.
int? parsePeso(String input) {
  final cleaned = input.replaceAll(RegExp(r'[₱,\s]'), '');
  if (cleaned.isEmpty || !RegExp(r'^\d*(\.\d{0,2})?$').hasMatch(cleaned)) return null;
  final parts = cleaned.split('.');
  final whole = parts[0].isEmpty ? 0 : int.parse(parts[0]);
  final frac = parts.length > 1 ? (parts[1] + '00').substring(0, 2) : '00';
  return whole * 100 + int.parse(frac);
}

/// Centavos to an editable field value, e.g. 18500 -> "185.00".
String pesoInputText(int centavos) => '${centavos ~/ 100}.${(centavos % 100).toString().padLeft(2, '0')}';
