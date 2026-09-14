// Coverage flush goroutine for long-running Go binaries built with `go
// build -cover`. We add this file to the target's main package at image-
// build time so the import is unconditional.
//
// Why this exists: a -cover binary writes counters to GOCOVERDIR only on
// process exit (via runtime atexit). For a server that stays up for the
// full fuzz run the sidecar would never see fresh data. WriteCountersDir
// dumps the in-memory counters to disk; calling it periodically gives
// the sidecar a moving baseline to aggregate.
//
// SIGUSR1 also triggers a flush so an operator (or a test harness) can
// force-snapshot without waiting for the next tick.
//
// IMPORTANT: the binary must be built with `-covermode=atomic`. The
// default mode is `set`, which records only "hit / not hit" without
// counters and refuses runtime emission via WriteCountersDir.

//go:build cov_flush

package main

import (
	"fmt"
	"os"
	"os/signal"
	"runtime/coverage"
	"syscall"
	"time"
)

func init() {
	dir := os.Getenv("GOCOVERDIR")
	if dir == "" {
		return
	}
	resetFile := os.Getenv("GOCOV_RESET_FILE")
	if resetFile == "" {
		resetFile = dir + "/reset.request"
	}
	intervalEnv := os.Getenv("GOCOV_FLUSH_INTERVAL_SECONDS")
	interval := 30 * time.Second
	if intervalEnv != "" {
		if n, err := time.ParseDuration(intervalEnv + "s"); err == nil && n > 0 {
			interval = n
		}
	}
	go func() {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "cov_flush: mkdir %s: %v\n", dir, err)
		}
		if err := coverage.WriteMetaDir(dir); err != nil {
			fmt.Fprintf(os.Stderr, "cov_flush: WriteMetaDir: %v\n", err)
		}
		fmt.Fprintf(os.Stderr, "cov_flush: started, dir=%s interval=%s pid=%d\n", dir, interval, os.Getpid())
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGUSR1)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		flush := func(reason string) {
			if err := coverage.WriteCountersDir(dir); err != nil {
				fmt.Fprintf(os.Stderr, "cov_flush: WriteCountersDir (%s): %v\n", reason, err)
			}
		}
		reset := func(reason string) {
			if err := coverage.ClearCounters(); err != nil {
				fmt.Fprintf(os.Stderr, "cov_flush: ClearCounters (%s): %v\n", reason, err)
			}
			if resetFile != "" {
				_ = os.Remove(resetFile)
			}
		}
		for {
			select {
			case <-sigCh:
				if resetFile != "" {
					if _, err := os.Stat(resetFile); err == nil {
						reset("usr1")
						continue
					}
				}
				flush("usr1")
			case <-ticker.C:
				flush("tick")
			}
		}
	}()
}
