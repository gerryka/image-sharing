package connlimit

import (
	"net"
	"testing"
	"time"
)

func TestPerIPAndTotal(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	l := New(raw, 10, 2)
	defer l.Close()

	accepted := make(chan net.Conn, 10)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			accepted <- c
		}
	}()

	dial := func() net.Conn {
		c, err := net.Dial("tcp", raw.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	c1, c2, c3 := dial(), dial(), dial()
	defer c1.Close()
	defer c2.Close()

	// Die dritte Verbindung derselben IP wird serverseitig sofort geschlossen.
	c3.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := c3.Read(make([]byte, 1)); err == nil {
		t.Fatal("third connection should be closed")
	}
	s1, s2 := <-accepted, <-accepted
	if total, per := l.Counts("127.0.0.1"); total != 2 || per != 2 {
		t.Fatalf("counts = %d/%d, want 2/2", total, per)
	}

	// Nach dem Schließen ist wieder Platz.
	s1.Close()
	s1.Close() // doppeltes Close zählt nur einmal
	if total, per := l.Counts("127.0.0.1"); total != 1 || per != 1 {
		t.Fatalf("after close counts = %d/%d, want 1/1", total, per)
	}
	c4 := dial()
	defer c4.Close()
	select {
	case s4 := <-accepted:
		s4.Close()
	case <-time.After(2 * time.Second):
		t.Fatal("fourth connection not accepted")
	}
	s2.Close()
}
