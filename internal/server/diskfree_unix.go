//go:build unix

package server

import "syscall"

// freeBytes liefert den für unprivilegierte Prozesse freien Platz auf dem Dateisystem von path.
func freeBytes(path string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}
