import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_libp2p/flutter_libp2p.dart';
import 'package:test/test.dart';

void main() {
  test('dart host can connect to a go-libp2p peer', () async {
    if (!await _hasGoToolchain()) {
      markTestSkipped('Go toolchain is not installed');
      return;
    }

    final server = await _startGoServer();
    addTearDown(server.dispose);

    final host = await Libp2pHost.create();
    addTearDown(host.close);

    final connection = await host.connect(Multiaddr.parse(server.multiaddr));
    final latency = await host.ping(connection);
    expect(latency, isA<Duration>());

    final identify = await host.identify(connection);
    expect(identify.agentVersion, contains('go-libp2p-interop'));
    expect(identify.protocols, contains(PingProtocol.protocolId));
  });

  test('go-libp2p peer can connect to a dart host', () async {
    if (!await _hasGoToolchain()) {
      markTestSkipped('Go toolchain is not installed');
      return;
    }

    final host = await Libp2pHost.create();
    addTearDown(host.close);

    final listenAddr = await host.listen(Multiaddr.parse('/ip4/127.0.0.1/tcp/0'));
    final result = await Process.run(
      'go',
      ['run', '.', 'client', listenAddr.toString()],
      workingDirectory: _goPeerFixtureDirectory.path,
    );

    if (result.exitCode != 0) {
      fail(
        'go interop client failed with exit code ${result.exitCode}\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
      );
    }

    final output = jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
    expect(output['ok'], isTrue);
  });
}

Directory get _goPeerFixtureDirectory =>
    Directory(Directory.current.uri.resolve('testdata/go_libp2p_peer').toFilePath());

Future<bool> _hasGoToolchain() async {
  try {
    final result = await Process.run('go', ['version']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<_GoServer> _startGoServer() async {
  final process = await Process.start(
    'go',
    ['run', '.', 'server'],
    workingDirectory: _goPeerFixtureDirectory.path,
  );

  final stdoutLines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  final stderrBuffer = StringBuffer();
  final stderrSub = process.stderr
      .transform(utf8.decoder)
      .listen(stderrBuffer.write);

  final firstLine = await stdoutLines.first.timeout(const Duration(seconds: 30));
  final ready = jsonDecode(firstLine) as Map<String, dynamic>;

  return _GoServer(
    process: process,
    stderrSubscription: stderrSub,
    multiaddr: ready['multiaddr'] as String,
  );
}

class _GoServer {
  _GoServer({
    required this.process,
    required this.stderrSubscription,
    required this.multiaddr,
  });

  final Process process;
  final StreamSubscription<String> stderrSubscription;
  final String multiaddr;

  Future<void> dispose() async {
    await stderrSubscription.cancel();
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
  }
}
