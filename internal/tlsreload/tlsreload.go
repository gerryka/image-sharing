// Package tlsreload lädt Zertifikat und Key neu, sobald sich die Dateien
// ändern (z. B. nach einem Let's-Encrypt-Renewal) – ohne Neustart.
package tlsreload

import (
	"context"
	"crypto/tls"
	"log"
	"os"
	"sync"
	"time"
)

type Reloader struct {
	certFile, keyFile string

	mu       sync.RWMutex
	cert     *tls.Certificate
	certStat fileStamp
	keyStat  fileStamp
}

type fileStamp struct {
	mod  time.Time
	size int64
}

func stamp(path string) (fileStamp, error) {
	fi, err := os.Stat(path) // folgt Symlinks (live/ → archive/)
	if err != nil {
		return fileStamp{}, err
	}
	return fileStamp{mod: fi.ModTime(), size: fi.Size()}, nil
}

func New(certFile, keyFile string) (*Reloader, error) {
	r := &Reloader{certFile: certFile, keyFile: keyFile}
	if _, err := r.reload(true); err != nil {
		return nil, err
	}
	return r, nil
}

// reload lädt das Zertifikat, wenn sich eine der Dateien geändert hat (oder force).
func (r *Reloader) reload(force bool) (bool, error) {
	cs, err := stamp(r.certFile)
	if err != nil {
		return false, err
	}
	ks, err := stamp(r.keyFile)
	if err != nil {
		return false, err
	}
	r.mu.RLock()
	unchanged := cs == r.certStat && ks == r.keyStat
	r.mu.RUnlock()
	if unchanged && !force {
		return false, nil
	}
	cert, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		return false, err
	}
	r.mu.Lock()
	r.cert, r.certStat, r.keyStat = &cert, cs, ks
	r.mu.Unlock()
	return true, nil
}

// Watch prüft im angegebenen Intervall auf Änderungen, bis ctx endet.
func (r *Reloader) Watch(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			changed, err := r.reload(false)
			if err != nil {
				// Altes Zertifikat behalten; Renewal ist evtl. gerade mitten im Schreiben.
				log.Printf("tls reload: %v", err)
			} else if changed {
				log.Printf("tls: certificate reloaded")
			}
		}
	}
}

func (r *Reloader) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cert, nil
}
