package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"quant-server/internal/server"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		healthcheck()
		return
	}

	config, err := server.LoadConfig()
	if err != nil {
		log.Fatal(err)
	}
	application, err := server.New(config)
	if err != nil {
		log.Fatal(err)
	}

	cleanupContext, stopCleanup := context.WithCancel(context.Background())
	defer stopCleanup()
	go application.StartCleanup(cleanupContext)

	httpServer := &http.Server{
		Addr:              config.ListenAddr,
		Handler:           application.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       90 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("Quant Server listening on %s", config.ListenAddr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	stopCleanup()

	shutdownContext, cancelShutdown := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancelShutdown()
	if err := httpServer.Shutdown(shutdownContext); err != nil {
		log.Printf("HTTP shutdown incomplete: %v", err)
	}
	if !application.WaitForJobs(shutdownContext) {
		log.Printf("shutdown completed with unfinished jobs")
	}
}

func healthcheck() {
	url := os.Getenv("QUANT_HEALTHCHECK_URL")
	if url == "" {
		url = "http://127.0.0.1:8080/healthz"
	}
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get(url)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "unexpected health status: %d\n", response.StatusCode)
		os.Exit(1)
	}
}
