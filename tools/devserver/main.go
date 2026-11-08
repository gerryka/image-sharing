// Command devserver startet den echten ImgShare-Server ohne TLS auf Loopback,
// mit temporärem Datenordner – für Integrationstests der Clients.
//
//	go run ./tools/devserver -addr 127.0.0.1:47001 -invite devinvite-0123456789
//
// -drop-after schließt jede Verbindung nach der angegebenen Dauer hart
// (simuliert Ruhezustand/Netzabriss für Reconnect-Tests).
package main

import (
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"imgshare/internal/server"
	"imgshare/internal/store"
)

type dropListener struct {
	net.Listener
	after time.Duration
}

func (l dropListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil && l.after > 0 {
		time.AfterFunc(l.after, func() { c.Close() })
	}
	return c, err
}

func main() {
	addr := flag.String("addr", "127.0.0.1:47001", "Listen-Adresse")
	invite := flag.String("invite", "devinvite-0123456789", "ROOM_CREATE_SECRET (mind. 16 Zeichen)")
	dropAfter := flag.Duration("drop-after", 0, "jede Verbindung nach dieser Dauer schließen (0 = nie)")
	flag.Parse()

	dir, err := os.MkdirTemp("", "imgshare-dev-")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(dir)
	st, err := store.Open(dir)
	if err != nil {
		log.Fatal(err)
	}
	defer st.Close()

	srv := server.New(server.Config{
		MaxBlobBytes:     25 << 20,
		MaxMessageBytes:  64 << 10,
		RoomCreateSecret: *invite,
		MaxRooms:         1000,
		RoomQuotaBytes:   2 << 30,
		MinFreeBytes:     1,
		MaxWSTotal:       200,
		MaxListBytes:     8 << 20,
	}, st)

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("listening http://%s (data=%s, drop-after=%s)", *addr, dir, *dropAfter)
	log.Fatal(http.Serve(dropListener{ln, *dropAfter}, srv))
}
