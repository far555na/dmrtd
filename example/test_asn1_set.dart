import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';

void main() {
  var bytes = Uint8List.fromList([0xA0, 0x02, 0x02, 0x00]);
  var certSet = ASN1Set.fromBytes(bytes);
  print(certSet.elements);
}
