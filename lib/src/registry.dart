import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'blake2b/blake2b_hash.dart';
import 'skydb.dart';
import 'config.dart';

final unencodedPath = '/skynet/registry';

class RegistryEntry {
  //' Uint8List tweak;
  String datakey;
  Uint8List hashedDatakey;

  Uint8List data;
  int revision;

  RegistryEntry({/* this.tweak, */ this.datakey, this.data, this.revision});

  Uint8List toBytes() => Uint8List.fromList([
        ...withPadding(revision),
        ...data,
      ]);

  RegistryEntry.fromBytes(List<int> bytes) {
    revision = decodeUint8(bytes.sublist(0, 8));
    data = Uint8List.fromList(bytes.sublist(8));
  }

  Uint8List hash() {
    if (datakey != null) hashedDatakey = hashDatakey(datakey);

    final list = Uint8List.fromList([
      ...hashedDatakey,
      ...withPadding(data.length),
      ...data,
      ...withPadding(revision),
    ]);

    return Blake2bHash.hashWithDigestSize(
      256,
      list,
    );
  }
}

class SignedRegistryEntry {
  RegistryEntry entry;
  Signature signature;

  void setPublicKey(List<int> publicKey) {
    signature = Signature(signature.bytes, publicKey: PublicKey(publicKey));
  }

  Uint8List toBytes() =>
      Uint8List.fromList([...signature.bytes, ...entry.toBytes()]);

  SignedRegistryEntry.fromBytes(List<int> bytes, {List<int> publicKeyBytes}) {
    signature = Signature(bytes.sublist(0, 64),
        publicKey: publicKeyBytes == null ? null : PublicKey(publicKeyBytes));

    entry = RegistryEntry.fromBytes(bytes.sublist(64));
  }

  Map toJson() => {
        'datakey':
            hex.encode(entry.hashedDatakey ?? hashDatakey(entry.datakey)),
        'data': hex.encode(entry.data),
        'revision': entry.revision,
        'signature': hex.encode(signature.bytes),
      };

  SignedRegistryEntry.fromJson(Map m) {
    // TODO!
    signature = Signature(
      hex.decode(m['signature']),
    );
    entry = RegistryEntry(
      /* tweak: hex.decode(m['tweak']), */
      data: hex.decode(m['data']),
      revision: m['revision'],
    );

    if (m['datakey'] != null) entry.datakey = m['datakey'];
  }

  SignedRegistryEntry({this.entry, this.signature});
}

Uint8List hashDatakey(String datakey) {
  final l = utf8.encode(datakey);
  final list = Uint8List.fromList([
    ...withPadding(l.length),
    ...l,
  ]);

  return Blake2bHash.hashWithDigestSize(
    256,
    list,
  );
}

Future<SignedRegistryEntry> getEntry(
  SkynetUser user,
  String datakey,
) async {
  final uri = Uri.https(SkynetConfig.host, unencodedPath, {
    'publickey': 'ed25519:${user.id}',
    'datakey': hex.encode(hashDatakey(
        datakey)) /* hex.encode(utf8.encode(json.encode(
      fileID.toJson(),
    ))) */
    ,
  });

  // print(uri.toString());

  try {
    final res = await http.get(uri).timeout(Duration(seconds: 10));
    if (res.statusCode == 200) {
      final data = json.decode(res.body);

      final srv = SignedRegistryEntry(
        entry: RegistryEntry(
          datakey: datakey,
          data: hex.decode(data['data']),
          revision: data['revision'],
        ),
        signature:
            Signature(hex.decode(data['signature']), publicKey: user.publicKey),
      );

      final verified = await ed25519.verify(srv.entry.hash(), srv.signature);

      if (!verified) throw Exception('Invalid signature found');

      return srv;
    } else if (res.statusCode == 404) {
      return null;
    }
    throw Exception('unexpected response status code ${res.statusCode}');
  } catch (e) {
    /* print(e); */
    return null;
  }
}

Future<bool> setEntry(
  SkynetUser user,
  String datakey,
  SignedRegistryEntry srv,
) async {
  final uri = Uri.https(SkynetConfig.host, unencodedPath);

  final res = await http.post(uri,
      body: json.encode({
        'publickey': {
          'algorithm': 'ed25519',
          'key': user.publicKey.bytes,
        },
        'datakey': hex.encode(hashDatakey(datakey)),
        'revision': srv.entry.revision,
        'data': srv.entry.data,
        'signature': srv.signature.bytes,
      }));

  if (res.statusCode == 204) {
    return true;
  }
  print(res.body);
  throw Exception('unexpected response status code ${res.statusCode}');
}
