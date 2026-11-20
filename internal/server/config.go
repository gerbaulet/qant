package server

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"time"
)

const (
	defaultListenAddr        = ":8080"
	defaultDataDir           = "/data"
	defaultOpenRouterBaseURL = "https://openrouter.ai/api/v1"
)

type Config struct {
	ListenAddr           string
	DataDir              string
	OpenRouterBaseURL    *url.URL
	AllowUnauthenticated bool
	MaxConcurrentJobs    int
	MaxRequestBytes      int64
	MaxResponseBytes     int64
	JobTTL               time.Duration
	UpstreamTimeout      time.Duration
}

func LoadConfig() (Config, error) {
	baseURL, err := url.Parse(envString("QUANT_OPENROUTER_BASE_URL", defaultOpenRouterBaseURL))
	if err != nil || baseURL.Scheme != "https" || baseURL.Host == "" {
		return Config{}, fmt.Errorf("QUANT_OPENROUTER_BASE_URL must be an absolute HTTPS URL")
	}

	allowUnauthenticated, err := envBool("QUANT_ALLOW_UNAUTHENTICATED", false)
	if err != nil {
		return Config{}, err
	}
	maxConcurrentJobs, err := envInt("QUANT_MAX_CONCURRENT_JOBS", 3)
	if err != nil || maxConcurrentJobs < 1 || maxConcurrentJobs > 32 {
		return Config{}, fmt.Errorf("QUANT_MAX_CONCURRENT_JOBS must be between 1 and 32")
	}
	maxRequestBytes, err := envInt64("QUANT_MAX_REQUEST_BYTES", 25*1024*1024)
	if err != nil || maxRequestBytes < 1024 {
		return Config{}, fmt.Errorf("QUANT_MAX_REQUEST_BYTES must be at least 1024")
	}
	maxResponseBytes, err := envInt64("QUANT_MAX_RESPONSE_BYTES", 10*1024*1024)
	if err != nil || maxResponseBytes < 1024 {
		return Config{}, fmt.Errorf("QUANT_MAX_RESPONSE_BYTES must be at least 1024")
	}
	jobTTL, err := envDuration("QUANT_JOB_TTL", time.Hour)
	if err != nil || jobTTL < time.Minute {
		return Config{}, fmt.Errorf("QUANT_JOB_TTL must be at least one minute")
	}
	upstreamTimeout, err := envDuration("QUANT_UPSTREAM_TIMEOUT", 2*time.Minute)
	if err != nil || upstreamTimeout < time.Second {
		return Config{}, fmt.Errorf("QUANT_UPSTREAM_TIMEOUT must be at least one second")
	}

	return Config{
		ListenAddr:           envString("QUANT_LISTEN_ADDR", defaultListenAddr),
		DataDir:              envString("QUANT_DATA_DIR", defaultDataDir),
		OpenRouterBaseURL:    baseURL,
		AllowUnauthenticated: allowUnauthenticated,
		MaxConcurrentJobs:    maxConcurrentJobs,
		MaxRequestBytes:      maxRequestBytes,
		MaxResponseBytes:     maxResponseBytes,
		JobTTL:               jobTTL,
		UpstreamTimeout:      upstreamTimeout,
	}, nil
}

func envString(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func envBool(name string, fallback bool) (bool, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", name)
	}
	return parsed, nil
}

func envInt(name string, fallback int) (int, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return parsed, nil
}

func envInt64(name string, fallback int64) (int64, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return parsed, nil
}

func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be a duration such as 30s or 2m", name)
	}
	return parsed, nil
}
