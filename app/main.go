package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const mib = 1024 * 1024

type app struct {
	chaosEnabled bool
	crash        func()
	mu           sync.Mutex
	latency      time.Duration
	leakStop     chan struct{}
	allocations  [][]byte
	metrics      metrics
}

func main() {
	server := &app{chaosEnabled: os.Getenv("CHAOS_ENABLED") == "true", crash: func() { os.Exit(1) }}
	path := os.Getenv("HEAP_PROFILE_PATH")
	if path == "" {
		path = "/diagnostics/heap.pprof"
	}
	limit := uint64(128 * mib)
	if value := os.Getenv("MEMORY_LIMIT_BYTES"); value != "" {
		n, err := strconv.ParseUint(value, 10, 64)
		if err != nil || n == 0 {
			log.Fatal("MEMORY_LIMIT_BYTES must contain a positive byte count")
		}
		limit = n
	}
	go watchMemory(path, limit)

	httpServer := &http.Server{
		Addr:              ":8080",
		Handler:           server,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serveErr := make(chan error, 1)
	go func() { serveErr <- httpServer.ListenAndServe() }()
	select {
	case err := <-serveErr:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	case <-ctx.Done():
		deadline, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(deadline); err != nil {
			log.Printf("graceful shutdown: %v", err)
		}
	}
}

func (a *app) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	path, method := route(r.URL.Path)
	status := http.StatusOK
	defer func() { a.metrics.observe(path, status, time.Since(start).Seconds()) }()

	switch {
	case method == "" || method == http.MethodPost && !a.chaosEnabled:
		status = http.StatusNotFound
		http.NotFound(w, r)
		return
	case r.Method != method:
		status = http.StatusMethodNotAllowed
		w.Header().Set("Allow", method)
		http.Error(w, "method not allowed", status)
		return
	}

	switch path {
	case "/healthz":
		fmt.Fprintln(w, "ok")
	case "/readyz", "/work":
		a.mu.Lock()
		delay := a.latency
		a.mu.Unlock()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-r.Context().Done():
				status = http.StatusRequestTimeout
				return
			}
		}
		fmt.Fprintln(w, "ok")
	case "/metrics":
		a.writeMetrics(w)
	case "/chaos/crash":
		status = http.StatusAccepted
		w.WriteHeader(status)
		fmt.Fprintln(w, "crashing")
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		a.crash()
	case "/chaos/leak":
		status = http.StatusAccepted
		a.startLeak()
		w.WriteHeader(status)
	case "/chaos/latency":
		value := r.URL.Query().Get("ms")
		if value == "" {
			value = "1500"
		}
		ms, err := strconv.Atoi(value)
		if err != nil || ms < 1 || ms > 10000 {
			status = http.StatusBadRequest
			http.Error(w, "ms must be between 1 and 10000", status)
			return
		}
		a.mu.Lock()
		a.latency = time.Duration(ms) * time.Millisecond
		a.mu.Unlock()
		status = http.StatusAccepted
		w.WriteHeader(status)
	case "/chaos/reset":
		a.reset()
		status = http.StatusNoContent
		w.WriteHeader(status)
	}
}

func route(path string) (string, string) {
	switch path {
	case "/healthz", "/readyz", "/work", "/metrics":
		return path, http.MethodGet
	case "/chaos/crash", "/chaos/leak", "/chaos/latency", "/chaos/reset":
		return path, http.MethodPost
	default:
		return "unmatched", ""
	}
}

func (a *app) startLeak() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.leakStop != nil {
		return
	}
	stop := make(chan struct{})
	a.leakStop = stop
	go a.leak(stop)
}

func (a *app) leak(stop <-chan struct{}) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			a.mu.Lock()
			if a.leakStop != stop || len(a.allocations) >= 256 {
				a.mu.Unlock()
				return
			}
			chunk := make([]byte, mib)
			for i := 0; i < len(chunk); i += 4096 {
				chunk[i] = 1
			}
			a.allocations = append(a.allocations, chunk)
			a.mu.Unlock()
		}
	}
}

func (a *app) reset() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.latency = 0
	if a.leakStop != nil {
		close(a.leakStop)
		a.leakStop = nil
		a.allocations = nil
		runtime.GC()
	}
}
