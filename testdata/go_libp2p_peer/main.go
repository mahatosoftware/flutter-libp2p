package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p-mplex"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	noise "github.com/libp2p/go-libp2p/p2p/security/noise"
	"google.golang.org/protobuf/encoding/protowire"
)

const (
	pingProtocolID     = protocol.ID("/ipfs/ping/1.0.0")
	identifyProtocolID = protocol.ID("/ipfs/id/1.0.0")
)

type readyMessage struct {
	PeerID    string `json:"peer_id"`
	Multiaddr string `json:"multiaddr"`
}

type identifySnapshot struct {
	ProtocolVersion string
	AgentVersion    string
	PublicKey       []byte
	ListenAddrs     [][]byte
	ObservedAddr    []byte
	Protocols       []string
}

func main() {
	if len(os.Args) < 2 {
		fatalf("usage: %s <server|client> [multiaddr]", os.Args[0])
	}

	switch os.Args[1] {
	case "server":
		if err := runServer(); err != nil {
			fatalErr(err)
		}
	case "client":
		if len(os.Args) != 3 {
			fatalf("usage: %s client <multiaddr>", os.Args[0])
		}
		if err := runClient(os.Args[2]); err != nil {
			fatalErr(err)
		}
	default:
		fatalf("unknown mode %q", os.Args[1])
	}
}

func runServer() error {
	h, err := newInteropHost()
	if err != nil {
		return err
	}
	defer h.Close()

	h.SetStreamHandler(pingProtocolID, func(stream network.Stream) {
		defer stream.Close()
		payload := make([]byte, 32)
		if _, err := io.ReadFull(stream, payload); err != nil {
			return
		}
		_, _ = stream.Write(payload)
	})

	h.SetStreamHandler(identifyProtocolID, func(stream network.Stream) {
		defer stream.Close()

		pubKey, err := h.Peerstore().PubKey(h.ID()).Raw()
		if err != nil {
			return
		}

		var observed []byte
		if conn := stream.Conn(); conn != nil && conn.RemoteMultiaddr() != nil {
			observed = conn.RemoteMultiaddr().Bytes()
		}

		listenAddrs := make([][]byte, 0, len(h.Addrs()))
		for _, addr := range h.Addrs() {
			listenAddrs = append(listenAddrs, addr.Bytes())
		}

		message := marshalIdentifySnapshot(identifySnapshot{
			ProtocolVersion: "ipfs/0.1.0",
			AgentVersion:    "go-libp2p-interop/0.1.0",
			PublicKey:       marshalPublicKey(pubKey),
			ListenAddrs:     listenAddrs,
			ObservedAddr:    observed,
			Protocols: []string{
				string(pingProtocolID),
				string(identifyProtocolID),
			},
		})

		if err := writeLengthPrefixed(stream, message); err != nil {
			return
		}
	})

	if len(h.Addrs()) == 0 {
		return errors.New("host has no listen addresses")
	}

	announce := readyMessage{
		PeerID:    h.ID().String(),
		Multiaddr: fmt.Sprintf("%s/p2p/%s", h.Addrs()[0].String(), h.ID().String()),
	}
	if err := json.NewEncoder(os.Stdout).Encode(announce); err != nil {
		return err
	}

	_, _ = io.Copy(io.Discard, os.Stdin)
	return nil
}

func runClient(target string) error {
	h, err := newInteropHost()
	if err != nil {
		return err
	}
	defer h.Close()

	info, err := peer.AddrInfoFromString(target)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := h.Connect(ctx, *info); err != nil {
		return err
	}

	if err := doPing(ctx, h, info.ID); err != nil {
		return err
	}

	if err := doIdentify(ctx, h, info.ID); err != nil {
		return err
	}

	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"ok":      true,
		"peer_id": info.ID.String(),
	})
}

func newInteropHost() (host.Host, error) {
	return libp2p.New(
		libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"),
		libp2p.Security(noise.ID, noise.New),
		libp2p.Muxer(mplex.ID, mplex.DefaultTransport),
	)
}

func doPing(ctx context.Context, h host.Host, peerID peer.ID) error {
	stream, err := h.NewStream(ctx, peerID, pingProtocolID)
	if err != nil {
		return err
	}
	defer stream.Close()

	payload := []byte("0123456789abcdefghijklmnopqrstuv")
	if _, err := stream.Write(payload); err != nil {
		return err
	}

	echo := make([]byte, len(payload))
	if _, err := io.ReadFull(stream, echo); err != nil {
		return err
	}

	if string(payload) != string(echo) {
		return fmt.Errorf("ping echo mismatch")
	}

	return nil
}

func doIdentify(ctx context.Context, h host.Host, peerID peer.ID) error {
	stream, err := h.NewStream(ctx, peerID, identifyProtocolID)
	if err != nil {
		return err
	}
	defer stream.Close()

	message, err := readLengthPrefixed(stream)
	if err != nil {
		return err
	}

	agentVersion, protocols, err := parseIdentifyResponse(message)
	if err != nil {
		return err
	}

	if agentVersion == "" {
		return fmt.Errorf("identify response did not include agent version")
	}
	if len(protocols) == 0 {
		return fmt.Errorf("identify response did not include protocols")
	}

	return nil
}

func writeLengthPrefixed(w io.Writer, payload []byte) error {
	header := protowire.AppendVarint(nil, uint64(len(payload)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func readLengthPrefixed(r io.Reader) ([]byte, error) {
	length, err := readUVarint(r)
	if err != nil {
		return nil, err
	}

	payload := make([]byte, length)
	_, err = io.ReadFull(r, payload)
	return payload, err
}

func readUVarint(r io.Reader) (uint64, error) {
	var (
		value uint64
		shift uint
	)
	for {
		var b [1]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, err
		}
		value |= uint64(b[0]&0x7f) << shift
		if b[0]&0x80 == 0 {
			return value, nil
		}
		shift += 7
		if shift > 63 {
			return 0, fmt.Errorf("varint too long")
		}
	}
}

func marshalIdentifySnapshot(snapshot identifySnapshot) []byte {
	var message []byte
	message = protowire.AppendBytes(protowire.AppendTag(message, 1, protowire.BytesType), snapshot.PublicKey)
	for _, addr := range snapshot.ListenAddrs {
		message = protowire.AppendBytes(protowire.AppendTag(message, 2, protowire.BytesType), addr)
	}
	for _, protocolName := range snapshot.Protocols {
		message = protowire.AppendString(protowire.AppendTag(message, 3, protowire.BytesType), protocolName)
	}
	message = protowire.AppendBytes(protowire.AppendTag(message, 4, protowire.BytesType), snapshot.ObservedAddr)
	message = protowire.AppendString(protowire.AppendTag(message, 5, protowire.BytesType), snapshot.ProtocolVersion)
	message = protowire.AppendString(protowire.AppendTag(message, 6, protowire.BytesType), snapshot.AgentVersion)
	return message
}

func marshalPublicKey(raw []byte) []byte {
	var message []byte
	message = protowire.AppendVarint(protowire.AppendTag(message, 1, protowire.VarintType), 1)
	message = protowire.AppendBytes(protowire.AppendTag(message, 2, protowire.BytesType), raw)
	return message
}

func parseIdentifyResponse(payload []byte) (string, []string, error) {
	var (
		agentVersion string
		protocols    []string
	)

	for len(payload) > 0 {
		fieldNumber, wireType, n := protowire.ConsumeTag(payload)
		if n < 0 {
			return "", nil, errors.New("failed to read identify tag")
		}
		payload = payload[n:]

		switch wireType {
		case protowire.BytesType:
			value, m := protowire.ConsumeBytes(payload)
			if m < 0 {
				return "", nil, errors.New("failed to read identify field")
			}
			payload = payload[m:]

			switch fieldNumber {
			case 3:
				protocols = append(protocols, string(value))
			case 6:
				agentVersion = string(value)
			}
		default:
			_, m := protowire.ConsumeFieldValue(fieldNumber, wireType, payload)
			if m < 0 {
				return "", nil, errors.New("failed to skip identify field")
			}
			payload = payload[m:]
		}
	}

	return agentVersion, protocols, nil
}

func fatalErr(err error) {
	fmt.Fprintln(os.Stderr, err.Error())
	os.Exit(1)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
