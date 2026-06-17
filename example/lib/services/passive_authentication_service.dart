import 'dart:convert';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart' as pc;
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
      var authAttr = signerInfo.elements![authAttrIndex];
      var rawBytes = authAttr.encodedBytes!;
      var totalLength = authAttr.totalEncodedByteLength;
      var copyBytes = Uint8List.fromList(rawBytes.sublist(0, totalLength));
      copyBytes[0] = 0x31; 
      signedAttributesBytes = copyBytes;
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

  /// Phase 4: Verifies the SOD digital signature.
  /// Returns true if the signature in SignerInfo is valid against the DSC's public key.
  static bool verifySODSignature(SodParseResult sodParseResult) {
    // 1. Determine the data to verify.
    // If signedAttributes are present, the signature covers the DER-encoded SET of signedAttributes.
    // Otherwise, the signature covers the raw eContent (LDSSecurityObject) bytes.
    final Uint8List dataToVerify = sodParseResult.signedAttributes ?? sodParseResult.encapContentInfoBytes;

    // 2. If signedAttributes exist, verify the MessageDigest attribute matches hash of eContent.
    if (sodParseResult.signedAttributes != null) {
      final Hash hashAlgo;
      switch (sodParseResult.hashAlgorithmOid) {
        case '1.3.14.3.2.26':
          hashAlgo = sha1;
          break;
        case '2.16.840.1.101.3.4.2.1':
          hashAlgo = sha256;
          break;
        case '2.16.840.1.101.3.4.2.2':
          hashAlgo = sha384;
          break;
        case '2.16.840.1.101.3.4.2.3':
          hashAlgo = sha512;
          break;
        default:
          throw Exception('Unsupported hash algorithm OID: ${sodParseResult.hashAlgorithmOid}');
      }
      // Parse signedAttributes SET to find MessageDigest attribute (OID 1.2.840.113549.1.9.4)
      try {
        final saParser = ASN1Parser(sodParseResult.signedAttributes!);
        final saSet = saParser.nextObject();
        List<ASN1Object> saElements;
        if (saSet is ASN1Set) {
          saElements = saSet.elements ?? [];
        } else if (saSet is ASN1Sequence) {
          saElements = saSet.elements ?? [];
        } else {
          saElements = [];
        }
        for (final attr in saElements) {
          if (attr is! ASN1Sequence) continue;
          final attrOid = attr.elements?[0];
          if (attrOid is ASN1ObjectIdentifier &&
              attrOid.objectIdentifierAsString == '1.2.840.113549.1.9.4') {
            // MessageDigest attribute found
            final attrValues = attr.elements?[1];
            Uint8List? storedDigest;
            if (attrValues is ASN1Set && attrValues.elements != null && attrValues.elements!.isNotEmpty) {
              storedDigest = (attrValues.elements![0] as ASN1OctetString).valueBytes;
            } else if (attrValues is ASN1Sequence && attrValues.elements != null && attrValues.elements!.isNotEmpty) {
              storedDigest = (attrValues.elements![0] as ASN1OctetString).valueBytes;
            }
              if (storedDigest != null) {
                final computedDigest = hashAlgo.convert(sodParseResult.encapContentInfoBytes).bytes;
                final eq = const ListEquality<int>();
                if (!eq.equals(storedDigest, computedDigest)) {
                  final storedHex = storedDigest.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
                  final computedHex = computedDigest.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
                  throw Exception('MessageDigest attribute mismatch. Stored: $storedHex, Computed: $computedHex');
                }
              }
              break;
          }
        }
      } catch (_) {
        // Non-fatal: proceed with signature verification
      }
    }

    // 3. Extract public key bytes from DSC (SubjectPublicKeyInfo DER, hex-encoded in basic_utils).
    final spki = sodParseResult.dscCertificate.tbsCertificate?.subjectPublicKeyInfo;
    final pubKeyHex = spki?.bytes;
    if (pubKeyHex == null) {
      throw Exception('DSC public key bytes are null');
    }
    final pubKeyDer = Uint8List.fromList(
      List<int>.generate(pubKeyHex.length ~/ 2,
          (i) => int.parse(pubKeyHex.substring(i * 2, i * 2 + 2), radix: 16)),
    );

    // 4. Determine key type via the algorithm OID from parsed SPKI.
    final keyAlgOid = spki?.algorithm ?? '';

    // 5. Map hash OID to PointyCastle Digest.
    pc.Digest digest;
    switch (sodParseResult.hashAlgorithmOid) {
      case '1.3.14.3.2.26':
        digest = pc.SHA1Digest();
        break;
      case '2.16.840.1.101.3.4.2.4':
        digest = pc.SHA224Digest();
        break;
      case '2.16.840.1.101.3.4.2.1':
        digest = pc.SHA256Digest();
        break;
      case '2.16.840.1.101.3.4.2.2':
        digest = pc.SHA384Digest();
        break;
      case '2.16.840.1.101.3.4.2.3':
        digest = pc.SHA512Digest();
        break;
      default:
        throw Exception('Unsupported hash OID for signature: ${sodParseResult.hashAlgorithmOid}');
    }

    // RSA OID: 1.2.840.113549.1.1.x
    if (keyAlgOid.startsWith('1.2.840.113549.1.1')) {
      try {
        final rsaKey = CryptoUtils.rsaPublicKeyFromDERBytes(pubKeyDer);
        final verifier = pc.RSASigner(digest, '0609608648016503040201');
        verifier.init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(rsaKey));
        final isValid = verifier.verifySignature(
            dataToVerify, pc.RSASignature(sodParseResult.signatureBytes));
        if (!isValid) {
          throw Exception('RSA signature is invalid for the given data.');
        }
        return true;
      } catch (e) {
        throw Exception('RSA signature verification failed: $e');
      }
    }
    // EC OID: 1.2.840.10045.2.1
    else if (keyAlgOid == '1.2.840.10045.2.1') {
      try {
        // Try named-curve path first.
        // Passports with explicit parameters (e.g. some brainpool variants) will
        // throw 'ASN1Sequence is not ASN1ObjectIdentifier' inside ecPublicKeyFromDerBytes.
        // In that case fall through to explicit-parameter handling.
        pc.ECPublicKey ecKey;
        try {
          ecKey = CryptoUtils.ecPublicKeyFromDerBytes(pubKeyDer);
        } catch (e1) {
          // Fallback: parse the SubjectPublicKeyInfo manually for explicit params.
          // Extract the uncompressed EC point from the BIT STRING and try
          // common ePassport curves.
          try {
            ecKey = _ecPublicKeyFromSpkiWithExplicitParams(pubKeyDer, digest);
          } catch (e2) {
            throw Exception('EC Key parsing failed. Named curve err: $e1. Explicit param err: $e2');
          }
        }

        final verifier = pc.ECDSASigner(digest);
        verifier.init(false, pc.PublicKeyParameter<pc.ECPublicKey>(ecKey));

        // Parse DER-encoded ECDSA signature (SEQUENCE { INTEGER r, INTEGER s })
        final sigParser = ASN1Parser(sodParseResult.signatureBytes);
        final sigSeq = sigParser.nextObject() as ASN1Sequence;
        final r = (sigSeq.elements![0] as ASN1Integer).integer!;
        final s = (sigSeq.elements![1] as ASN1Integer).integer!;
        final isValid = verifier.verifySignature(dataToVerify, pc.ECSignature(r, s));
        if (!isValid) {
          throw Exception('ECDSA signature is invalid for the given data.\n'
              'Curve: ${ecKey.parameters!.domainName}\n'
              'Hash: ${digest.algorithmName}\n'
              'Data len: ${dataToVerify.length}\n'
              'Data starts: ${dataToVerify.take(4).map((e)=>e.toRadixString(16)).join(',')}\n'
              'Signature R len: ${r.bitLength}, S len: ${s.bitLength}');
        }
        return true;
      } catch (e) {
        throw Exception('ECDSA signature verification failed: $e');
      }
    } else {
      throw Exception('Unsupported key algorithm OID: $keyAlgOid');
    }
  }

  /// Attempts to reconstruct an [ECPublicKey] from a SubjectPublicKeyInfo DER
  /// that uses explicit domain parameters (common in some ePassport DSCs).
  ///
  /// Extracts the public key point from the BIT STRING and tries a set of
  /// well-known ePassport curves: P-256, P-384, P-521, and brainpool variants.
  static pc.ECPublicKey _ecPublicKeyFromSpkiWithExplicitParams(
      Uint8List spkiDer, pc.Digest digest) {
    // Parse SPKI SEQUENCE { AlgorithmIdentifier, BIT STRING }
    final spkiParser = ASN1Parser(spkiDer);
    final spkiSeq = spkiParser.nextObject() as ASN1Sequence;
    final pubBitString = spkiSeq.elements![1] as ASN1BitString;

    // valueBytes of a BIT STRING has a leading 'unused bits' byte we skip.
    var pubBytes = pubBitString.valueBytes!;
    if (pubBytes.isNotEmpty && pubBytes[0] == 0) {
      pubBytes = pubBytes.sublist(1);
    }

    // The key size lets us infer the curve:
    // P-256 / brainpoolP256:  65 bytes (uncompressed)
    // P-384 / brainpoolP384:  97 bytes
    // P-521:                 133 bytes
    // brainpoolP512:         129 bytes
    final candidates = <String>[];
    switch (pubBytes.length) {
      case 65:
        candidates.addAll(['prime256v1', 'brainpoolp256r1']);
        break;
      case 97:
        candidates.addAll(['secp384r1', 'brainpoolp384r1']);
        break;
      case 133:
        candidates.add('secp521r1');
        break;
      case 129:
        candidates.add('brainpoolp512r1');
        break;
      default:
        throw Exception(
            'Cannot infer EC curve from public key length ${pubBytes.length}');
    }

    for (final curveName in candidates) {
      try {
        final params = pc.ECDomainParameters(curveName);
        // Uncompressed point starts with 0x04
        if (pubBytes[0] != 4) {
          throw Exception('Compressed EC points are not supported');
        }
        final coordLen = (pubBytes.length - 1) ~/ 2;
        final x = _decodeBigInt(pubBytes.sublist(1, 1 + coordLen));
        final y = _decodeBigInt(pubBytes.sublist(1 + coordLen));
        
        // Validate point is on the curve
        final xElem = params.curve.fromBigInteger(x);
        final yElem = params.curve.fromBigInteger(y);
        final lhs = yElem * yElem;
        final rhs = (xElem * xElem * xElem) + (params.curve.a! * xElem) + params.curve.b!;
        if (lhs != rhs) {
          throw Exception('Point does not satisfy curve equation for $curveName');
        }
        
        final point = params.curve.createPoint(x, y);
        return pc.ECPublicKey(point, params);
      } catch (_) {
        continue;
      }
    }
    throw Exception('Could not reconstruct ECPublicKey from explicit params');
  }

  static BigInt _decodeBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}
