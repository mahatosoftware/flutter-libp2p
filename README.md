# flutter_libp2p

A Flutter-friendly Dart implementation of core libp2p building blocks.

Current scope:

- `PeerId` generation from Ed25519 keys
- `Multiaddr` parsing and binary encoding
- multistream-select negotiation
- Noise transport security (`Noise_XX_25519_ChaChaPoly_SHA256`)
- mplex stream multiplexing
- TCP transport for `dart:io` platforms
- built-in `ping` and `identify`
- in-memory peer store and managed connection lifecycle
- service-backed protocol registry
- Kademlia-style peer/content routing foundation
- relay v2 reservation support

This package is intended as a practical foundation for Flutter and Dart apps
that need interoperable libp2p primitives on native platforms.

## Interop tests

The repository includes a Go fixture under
`testdata/go_libp2p_peer/` for cross-implementation tests against
`go-libp2p`.

Run them with:

```bash
flutter test test/go_interop_test.dart
```

If the `go` toolchain is not installed, the interop test bodies return early so
the rest of the Dart test suite can still run in constrained environments.
