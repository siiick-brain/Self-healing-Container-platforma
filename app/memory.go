package main

import (
	"log"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"time"
)

func watchMemory(path string, limit uint64) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	written := false
	for range ticker.C {
		usage := memoryUsage()
		if usage < limit*7/10 {
			written = false
		}
		if written || usage < limit*4/5 {
			continue
		}
		written = true
		runtime.GC()
		if err := writeHeapProfile(path); err != nil {
			log.Printf("write heap profile: %v", err)
		}
	}
}

func memoryUsage() uint64 {
	for _, path := range []string{"/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory/memory.usage_in_bytes"} {
		if body, err := os.ReadFile(path); err == nil {
			if value, err := strconv.ParseUint(strings.TrimSpace(string(body)), 10, 64); err == nil {
				return value
			}
		}
	}
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	return mem.Alloc
}

func writeHeapProfile(path string) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".heap-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	err = pprof.WriteHeapProfile(temp)
	closeErr := temp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temp.Name(), path)
}
