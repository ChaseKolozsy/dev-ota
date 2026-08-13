// emulator-ssh-bridge gives an Android emulator's DevOTA terminal a local,
// interactive shell without exposing an SSH daemon to the host network.
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"syscall"

	"github.com/creack/pty"
	"golang.org/x/crypto/ssh"
)

type options struct {
	listen         string
	hostKey        string
	authorizedKeys string
	acceptAnyKey   bool
	shell          string
	workdir        string
}

func main() {
	current, err := user.Current()
	if err != nil {
		log.Fatal(err)
	}
	defaultState := filepath.Join(current.HomeDir, ".local", "state", "devota")
	var opts options
	flag.StringVar(&opts.listen, "listen", "127.0.0.1:2224", "loopback address to listen on")
	flag.StringVar(&opts.hostKey, "host-key", filepath.Join(defaultState, "emulator_bridge_host_key"), "persistent RSA host-key path")
	flag.StringVar(&opts.authorizedKeys, "authorized-keys", filepath.Join(current.HomeDir, ".ssh", "authorized_keys"), "OpenSSH public-key file")
	flag.BoolVar(&opts.acceptAnyKey, "accept-any-key", false, "accept any public key (allowed only on a loopback listener)")
	flag.StringVar(&opts.shell, "shell", "/bin/bash", "interactive shell executable")
	flag.StringVar(&opts.workdir, "workdir", current.HomeDir, "initial shell directory")
	flag.Parse()
	if err := run(opts); err != nil {
		log.Fatal(err)
	}
}

func run(opts options) error {
	host, _, err := net.SplitHostPort(opts.listen)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}
	if opts.acceptAnyKey && !isLoopback(host) {
		return errors.New("--accept-any-key requires a loopback listen address")
	}
	if _, err := os.Stat(opts.shell); err != nil {
		return fmt.Errorf("shell: %w", err)
	}
	if info, err := os.Stat(opts.workdir); err != nil || !info.IsDir() {
		return fmt.Errorf("workdir must be an existing directory: %s", opts.workdir)
	}
	signer, err := loadOrCreateHostKey(opts.hostKey)
	if err != nil {
		return err
	}
	allowed, err := readAuthorizedKeys(opts.authorizedKeys)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if !opts.acceptAnyKey && len(allowed) == 0 {
		return fmt.Errorf("no keys found in %s; add one or use --accept-any-key on loopback", opts.authorizedKeys)
	}
	config := &ssh.ServerConfig{PublicKeyCallback: publicKeyCallback(allowed, opts.acceptAnyKey)}
	config.AddHostKey(signer)
	listener, err := net.Listen("tcp", opts.listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	log.Printf("DevOTA emulator SSH bridge listening on %s", opts.listen)
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go serve(conn, config, opts)
	}
}

func isLoopback(host string) bool {
	ip := net.ParseIP(host)
	return host == "localhost" || (ip != nil && ip.IsLoopback())
}

func loadOrCreateHostKey(path string) (ssh.Signer, error) {
	contents, err := os.ReadFile(path)
	if err == nil {
		return ssh.ParsePrivateKey(contents)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	encoded := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := os.WriteFile(path, encoded, 0600); err != nil {
		return nil, err
	}
	return ssh.NewSignerFromKey(key)
}

func readAuthorizedKeys(path string) (map[string]struct{}, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	keys := make(map[string]struct{})
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		key, _, _, _, err := ssh.ParseAuthorizedKey(scanner.Bytes())
		if err == nil {
			keys[string(key.Marshal())] = struct{}{}
		}
	}
	return keys, scanner.Err()
}

func publicKeyCallback(allowed map[string]struct{}, acceptAny bool) func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) {
	return func(_ ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		if acceptAny {
			return nil, nil
		}
		if _, ok := allowed[string(key.Marshal())]; ok {
			return nil, nil
		}
		return nil, errors.New("public key is not authorized")
	}
}

func serve(raw net.Conn, config *ssh.ServerConfig, opts options) {
	server, channels, requests, err := ssh.NewServerConn(raw, config)
	if err != nil {
		log.Printf("SSH handshake failed from %s: %v", raw.RemoteAddr(), err)
		raw.Close()
		return
	}
	defer server.Close()
	log.Printf("SSH session accepted for %s from %s", server.User(), raw.RemoteAddr())
	go ssh.DiscardRequests(requests)
	for incoming := range channels {
		if incoming.ChannelType() != "session" {
			incoming.Reject(ssh.UnknownChannelType, "session only")
			continue
		}
		channel, requests, err := incoming.Accept()
		if err == nil {
			go session(channel, requests, opts)
		}
	}
}

func session(channel ssh.Channel, requests <-chan *ssh.Request, opts options) {
	defer channel.Close()
	size := &pty.Winsize{Rows: 40, Cols: 120}
	var terminal *os.File
	for request := range requests {
		switch request.Type {
		case "pty-req":
			var payload struct {
				Term                    string
				Width, Height           uint32
				PixelWidth, PixelHeight uint32
				Modes                   string
			}
			if ssh.Unmarshal(request.Payload, &payload) == nil {
				size.Cols, size.Rows = uint16(payload.Width), uint16(payload.Height)
			}
			request.Reply(true, nil)
		case "window-change":
			if terminal != nil {
				var payload struct{ Width, Height, PixelWidth, PixelHeight uint32 }
				if ssh.Unmarshal(request.Payload, &payload) == nil {
					pty.Setsize(terminal, &pty.Winsize{Cols: uint16(payload.Width), Rows: uint16(payload.Height)})
				}
			}
		case "shell":
			cmd := exec.Command(opts.shell, "-l")
			cmd.Dir = opts.workdir
			cmd.Env = append(os.Environ(), "TERM=xterm-256color")
			var err error
			terminal, err = pty.StartWithSize(cmd, size)
			if err != nil {
				request.Reply(false, nil)
				return
			}
			request.Reply(true, nil)
			go io.Copy(terminal, channel)
			io.Copy(channel, terminal)
			terminal.Close()
			cmd.Wait()
			if status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok {
				channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{uint32(status.ExitStatus())}))
			}
			return
		default:
			request.Reply(false, nil)
		}
	}
}
