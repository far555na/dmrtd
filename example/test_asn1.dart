import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';

void main() {
  var bytes = Uint8List.fromList([0xA0, 0x02, 0x30, 0x00]);
  var parser = ASN1Parser(bytes);
  var obj = parser.nextObject();
  print(obj.runtimeType);
  print(obj.valueBytes);
}
