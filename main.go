// imgshare – "dummer" Relay-Server für Ende-zu-Ende-verschlüsseltes Bildsharing.
// Siehe docs/PROTOCOL.md.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"imgshare/internal/connlimit"
	"imgshare/internal/server"
	"imgshare/internal/store"
	"imgshare/internal/tlsreload"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int64) int64 {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n <= 0 {
		log.Fatalf("%s: ungültiger Wert %q", key, v)
	}
	return n
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	addr := env("LISTEN_ADDR", ":47000")

	// Für den Docker-HEALTHCHECK (distroless hat kein curl).
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck(addr))
	}

	certFile := env("TLS_CERT", "/certs/fullchain.pem")
	keyFile := env("TLS_KEY", "/certs/privkey.pem")
	dataDir := env("DATA_DIR", "/data")
	cfg := server.Config{
		MaxBlobBytes:     envInt("MAX_BLOB_BYTES", 25<<20),
		MaxMessageBytes:  envInt("MAX_MESSAGE_BYTES", 64<<10),
		RoomCreateSecret: os.Getenv("ROOM_CREATE_SECRET"),
		MaxRooms:         envInt("MAX_ROOMS", 100),
		RoomQuotaBytes:   envInt("ROOM_QUOTA_BYTES", 2<<30),
		MinFreeBytes:     envInt("MIN_FREE_BYTES", 1<<30),
		MaxWSTotal:       int(envInt("MAX_WS_TOTAL", 200)),
		MaxListBytes:     envInt("MAX_LIST_BYTES", 8<<20),
	}
	maxConns := int(envInt("MAX_CONNS", 256))
	maxConnsPerIP := int(envInt("MAX_CONNS_PER_IP", 32))
	switch n := len(cfg.RoomCreateSecret); {
	case n == 0:
		log.Printf("WARNUNG: ROOM_CREATE_SECRET nicht gesetzt – es können keine neuen Räume angelegt werden")
	case n < 16:
		log.Fatalf("ROOM_CREATE_SECRET ist zu kurz (mindestens 16 Zeichen)")
	}

	st, err := store.Open(dataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer st.Close()

	reloader, err := tlsreload.New(certFile, keyFile)
	if err != nil {
		log.Fatalf("tls: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go reloader.Watch(ctx, 60*time.Second)
	srv := server.New(cfg, st)
	go srv.RunMaintenance(ctx)

	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second, // Blob-Uploads verlängern das selbst (server.uploadTimeout)
		WriteTimeout:      10 * time.Minute, // große Downloads über langsame Leitungen
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    16 << 10,
		TLSConfig: &tls.Config{
			MinVersion:     tls.VersionTLS12,
			GetCertificate: reloader.GetCertificate,
		},
	}

	go func() {
		<-ctx.Done()
		log.Printf("shutting down")
		srv.Shutdown()
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		httpSrv.Shutdown(sctx)
	}()

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	// Verbindungen begrenzen, bevor TLS-Handshakes Ressourcen kosten.
	limited := connlimit.New(ln, maxConns, maxConnsPerIP)

	log.Printf("listening on %s (data=%s, max_blob=%d, max_msg=%d, max_rooms=%d, quota=%d, conns=%d/%d per ip)",
		addr, dataDir, cfg.MaxBlobBytes, cfg.MaxMessageBytes, cfg.MaxRooms, cfg.RoomQuotaBytes, maxConns, maxConnsPerIP)
	if err := httpSrv.ServeTLS(limited, "", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("serve: %v", err)
	}
}

func healthcheck(addr string) int {
	port := addr[strings.LastIndex(addr, ":")+1:]
	c := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			// Lokaler Check gegen 127.0.0.1 – der Hostname im Zertifikat passt hier nicht.
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}
	resp, err := c.Get("https://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
