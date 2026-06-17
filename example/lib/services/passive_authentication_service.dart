import 'dart:convert';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/asn1.dart';
import 'package:dmrtd/dmrtd.dart';
import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'passive_authentication_result.dart';
class SodParseResult {
  final String hashAlgorithmOid;
  final Map<int, Uint8List> dataGroupHashes;
  final X509CertificateData dscCertificate;
  final Uint8List signatureBytes;
  final Uint8List? signedAttributes;
  final Uint8List encapContentInfoBytes; // The raw LDSSecurityObject bytes

  SodParseResult({
    required this.hashAlgorithmOid,
    required this.dataGroupHashes,
    required this.dscCertificate,
    required this.signatureBytes,
    this.signedAttributes,
    required this.encapContentInfoBytes,
  });
}

class PassiveAuthenticationService {
  static String _derToPem(Uint8List derBytes) {
    final base64Str = base64Encode(derBytes);
    final buffer = StringBuffer();
    buffer.writeln('-----BEGIN CERTIFICATE-----');
    for (int i = 0; i < base64Str.length; i += 64) {
      buffer.writeln(base64Str.substring(i, i + 64 > base64Str.length ? base64Str.length : i + 64));
    }
    buffer.writeln('-----END CERTIFICATE-----');
    return buffer.toString();
  }

  /// Parses the EF.SOD file, verifying CMS structures and extracting LDSSecurityObject, DSC, and SignerInfo.
  static SodParseResult parseSOD(Uint8List sodBytes) {
    var bytesToParse = sodBytes;
    if (bytesToParse.isNotEmpty && bytesToParse[0] == 0x77) {
      final tlv = TLV.fromBytes(bytesToParse);
      bytesToParse = Uint8List.fromList(tlv.value);
    }

    final parser = ASN1Parser(bytesToParse);
    final topLevelObj = parser.nextObject();
    if (topLevelObj is! ASN1Sequence) throw Exception('topLevel is not ASN1Sequence but ${topLevelObj.runtimeType}');
    final topLevel = topLevelObj;

    // 1. Verify outer OID is id-signedData (1.2.840.113549.1.7.2)
    final contentType = topLevel.elements![0] as ASN1ObjectIdentifier;
    if (contentType.objectIdentifierAsString != '1.2.840.113549.1.7.2') {
      throw Exception('SOD does not contain CMS SignedData');
    }

    // 2. Extract SignedData sequence
    final contextSpecificObj = topLevel.elements![1];
    if (contextSpecificObj.tag != 0xA0) throw Exception('Expected ContextSpecific [0] tag (0xA0), got ${contextSpecificObj.tag}');
    
    final innerParser = ASN1Parser(contextSpecificObj.valueBytes!);
    final signedDataObj = innerParser.nextObject();
    
    if (signedDataObj is! ASN1Sequence) throw Exception('signedData is not ASN1Sequence but ${signedDataObj.runtimeType}');
    final signedData = signedDataObj;
    
    // SignedData elements:
    // 0: Version
    // 1: DigestAlgorithms
    // 2: EncapContentInfo
    // 3: Certificates (optional, [0] IMPLICIT SET)
    // 4: Crls (optional, [1] IMPLICIT SET)
    // 5: SignerInfos (SET)
    
    final encapContentInfoObj = signedData.elements![2];
    if (encapContentInfoObj is! ASN1Sequence) throw Exception('encapContentInfo is not ASN1Sequence but ${encapContentInfoObj.runtimeType}');
    final encapContentInfo = encapContentInfoObj;
    
    final eContentType = encapContentInfo.elements![0] as ASN1ObjectIdentifier;
    if (eContentType.objectIdentifierAsString != '2.23.136.1.1.1') {
      throw Exception('eContentType is not id-icao-ldsSecurityObject');
    }

    // encapContentInfo.elements[1] is [0] EXPLICIT OCTET STRING
    final eContentWrapper = encapContentInfo.elements![1];
    if (eContentWrapper.tag != 0xA0) throw Exception('eContentWrapper tag is not 0xA0 but ${eContentWrapper.tag}');
    
    final eContentInnerParser = ASN1Parser(eContentWrapper.valueBytes!);
    final eContentOctetStringObj = eContentInnerParser.nextObject();
    if (eContentOctetStringObj is! ASN1OctetString) throw Exception('eContent is not ASN1OctetString but ${eContentOctetStringObj.runtimeType}');
    final eContentOctetString = eContentOctetStringObj;
    
    final ldsSecurityObjectBytes = eContentOctetString.valueBytes!;

    // 3. Parse LDSSecurityObject
    final ldsParser = ASN1Parser(ldsSecurityObjectBytes);
    final ldsSequenceObj = ldsParser.nextObject();
    if (ldsSequenceObj is! ASN1Sequence) throw Exception('ldsSequence is not ASN1Sequence but ${ldsSequenceObj.runtimeType}');
    final ldsSequence = ldsSequenceObj;
    
    // Elements: 0: Version, 1: HashAlgorithmIdentifier, 2: DataGroupHashValues
    final hashAlgSeqObj = ldsSequence.elements![1];
    if (hashAlgSeqObj is! ASN1Sequence) throw Exception('hashAlgSeq is not ASN1Sequence but ${hashAlgSeqObj.runtimeType}');
    final hashAlgSeq = hashAlgSeqObj;
    final hashAlgOid = (hashAlgSeq.elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString!;
    
    final dataGroupHashValuesObj = ldsSequence.elements![2];
    if (dataGroupHashValuesObj is! ASN1Sequence) throw Exception('dataGroupHashValues is not ASN1Sequence but ${dataGroupHashValuesObj.runtimeType}');
    final dataGroupHashValues = dataGroupHashValuesObj;
    
    final Map<int, Uint8List> dgHashes = {};
    for (var element in dataGroupHashValues.elements!) {
      if (element is! ASN1Sequence) throw Exception('dgHash element is not ASN1Sequence but ${element.runtimeType}');
      final dgHashSeq = element;
      final dgNumber = (dgHashSeq.elements![0] as ASN1Integer).integer!.toInt();
      final hashValue = (dgHashSeq.elements![1] as ASN1OctetString).valueBytes!;
      dgHashes[dgNumber] = hashValue;
    }

    // 4. Extract Certificates
    var certIndex = 3;
    ASN1Set? certSet;
    if (signedData.elements![certIndex].tag == 0xA0) { // Context specific [0]
       // In pointycastle, context specific tags might be parsed as sequences with the specific tag.
       certSet = ASN1Set.fromBytes(signedData.elements![certIndex].encodedBytes!);
       certIndex++;
    }

    if (certSet == null) {
      throw Exception('No certificates found in SOD');
    }
    
    // Parse the first certificate (DSC)
    final dscDer = certSet.elements![0].encodedBytes;
    final dscCertificate = X509Utils.x509CertificateFromPem(_derToPem(dscDer!));

    // 5. Extract SignerInfo
    var crlIndex = certIndex;
    if (signedData.elements![crlIndex].tag == 0xA1) { // CRLs
      crlIndex++;
    }
    
    final signerInfosSet = signedData.elements![crlIndex] as ASN1Set;
    final signerInfo = signerInfosSet.elements![0] as ASN1Sequence;
    
    // SignerInfo elements:
    // 0: Version
    // 1: IssuerAndSerialNumber or SubjectKeyIdentifier
    // 2: DigestAlgorithm
    // 3: AuthenticatedAttributes (optional, [0] IMPLICIT SET)
    // 4: DigestEncryptionAlgorithm (SignatureAlgorithm)
    // 5: EncryptedDigest (Signature)
    // 6: UnauthenticatedAttributes (optional, [1] IMPLICIT SET)
    
    int authAttrIndex = -1;
    for (int i = 0; i < signerInfo.elements!.length; i++) {
      if (signerInfo.elements![i].tag == 0xA0) {
        authAttrIndex = i;
        break;
      }
    }

    Uint8List? signedAttributesBytes;
    int sigAlgIndex = 3;
    if (authAttrIndex != -1) {
      // It's implicitly tagged SET, we can construct the SET bytes to verify signature later
      // The signature is over the SET, but its tag must be changed to 0x31 (SET) instead of 0xA0 for hashing
      var rawBytes = signerInfo.elements![authAttrIndex].encodedBytes!;
      rawBytes[0] = 0x31; 
      signedAttributesBytes = rawBytes;
      sigAlgIndex = authAttrIndex + 1;
    }

    final signatureOctetString = signerInfo.elements![sigAlgIndex + 1] as ASN1OctetString;

    return SodParseResult(
      hashAlgorithmOid: hashAlgOid,
      dataGroupHashes: dgHashes,
      dscCertificate: dscCertificate,
      signatureBytes: signatureOctetString.valueBytes!,
      signedAttributes: signedAttributesBytes,
      encapContentInfoBytes: ldsSecurityObjectBytes,
    );
  }

  /// Verifies the hashes of provided Data Groups against the hashes stored in the SOD.
  static PassiveAuthenticationResult verifyDataGroupHashes(
      SodParseResult sodParseResult, Map<int, Uint8List> providedDGs) {
    Hash algorithm;
    switch (sodParseResult.hashAlgorithmOid) {
      case '1.3.14.3.2.26':
        algorithm = sha1;
        break;
      case '2.16.840.1.101.3.4.2.1':
        algorithm = sha256;
        break;
      case '2.16.840.1.101.3.4.2.2':
        algorithm = sha384;
        break;
      case '2.16.840.1.101.3.4.2.3':
        algorithm = sha512;
        break;
      default:
        throw Exception('Unsupported hash algorithm OID: \${sodParseResult.hashAlgorithmOid}');
    }

    final Map<int, bool> dataGroupMatches = {};
    final List<int> unreadDataGroups = [];

    // Find unread DGs
    for (var dgNumber in sodParseResult.dataGroupHashes.keys) {
      if (!providedDGs.containsKey(dgNumber)) {
        unreadDataGroups.add(dgNumber);
      }
    }

    // Verify provided DGs
    final eq = const ListEquality<int>();
    for (var entry in providedDGs.entries) {
      final dgNumber = entry.key;
      final dgBytes = entry.value;

      if (sodParseResult.dataGroupHashes.containsKey(dgNumber)) {
        final expectedHash = sodParseResult.dataGroupHashes[dgNumber]!;
        final actualHash = algorithm.convert(dgBytes).bytes;
        dataGroupMatches[dgNumber] = eq.equals(expectedHash, actualHash);
      } else {
        // DG provided but not in SOD
        dataGroupMatches[dgNumber] = false;
      }
    }

    return PassiveAuthenticationResult(
      dataGroupMatches: dataGroupMatches,
      unreadDataGroups: unreadDataGroups,
      isSignatureValid: false, // Phase 4 stub
      isTrustChainValid: false, // Phase 5 stub
    );
  }
}
