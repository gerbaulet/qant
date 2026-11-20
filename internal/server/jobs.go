package server

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type JobStatus string

const (
	JobRunning   JobStatus = "running"
	JobSucceeded JobStatus = "succeeded"
	JobFailed    JobStatus = "failed"
)

var ErrIdempotencyConflict = errors.New("idempotency key was already used with another request")

type Job struct {
	ID             string    `json:"id"`
	OwnerHash      string    `json:"owner_hash"`
	IdempotencyKey string    `json:"idempotency_key"`
	RequestHash    string    `json:"request_hash"`
	Status         JobStatus `json:"status"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	Attempt        int       `json:"attempt"`
	UpstreamStatus int       `json:"upstream_status,omitempty"`
	ResponseBody   []byte    `json:"response_body,omitempty"`
	FailureCode    string    `json:"failure_code,omitempty"`
	FailureMessage string    `json:"failure_message,omitempty"`
	Retryable      bool      `json:"retryable,omitempty"`
}

type JobStore struct {
	mu    sync.Mutex
	dir   string
	ttl   time.Duration
	now   func() time.Time
	jobs  map[string]*Job
	byKey map[string]string
}

func NewJobStore(dir string, ttl time.Duration) (*JobStore, error) {
	store := &JobStore{
		dir:   dir,
		ttl:   ttl,
		now:   time.Now,
		jobs:  make(map[string]*Job),
		byKey: make(map[string]string),
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create data directory: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, fmt.Errorf("secure data directory: %w", err)
	}
	if err := store.load(); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *JobStore) CreateOrReuse(ownerHash, idempotencyKey, requestHash string) (Job, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.now().UTC()
	indexKey := ownerHash + "\x00" + idempotencyKey
	if existingID, ok := s.byKey[indexKey]; ok {
		existing := s.jobs[existingID]
		if existing != nil && existing.ExpiresAt.After(now) {
			if existing.RequestHash != requestHash {
				return Job{}, false, ErrIdempotencyConflict
			}
			if existing.Status == JobFailed && existing.Retryable {
				restarted := cloneJob(existing)
				restarted.Status = JobRunning
				restarted.UpdatedAt = now
				restarted.ExpiresAt = now.Add(s.ttl)
				restarted.Attempt++
				restarted.UpstreamStatus = 0
				restarted.ResponseBody = nil
				restarted.FailureCode = ""
				restarted.FailureMessage = ""
				restarted.Retryable = false
				if err := s.persistLocked(&restarted); err != nil {
					return Job{}, false, err
				}
				*existing = restarted
				return cloneJob(existing), true, nil
			}
			return cloneJob(existing), false, nil
		}
	}

	id, err := randomID()
	if err != nil {
		return Job{}, false, err
	}
	job := &Job{
		ID:             id,
		OwnerHash:      ownerHash,
		IdempotencyKey: idempotencyKey,
		RequestHash:    requestHash,
		Status:         JobRunning,
		CreatedAt:      now,
		UpdatedAt:      now,
		ExpiresAt:      now.Add(s.ttl),
		Attempt:        1,
	}
	if err := s.persistLocked(job); err != nil {
		return Job{}, false, err
	}
	s.jobs[id] = job
	s.byKey[indexKey] = id
	return cloneJob(job), true, nil
}

func (s *JobStore) Get(id, ownerHash string) (Job, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[id]
	if job == nil || job.OwnerHash != ownerHash || !job.ExpiresAt.After(s.now().UTC()) {
		return Job{}, false
	}
	return cloneJob(job), true
}

func (s *JobStore) Succeed(id string, status int, body []byte) error {
	return s.finish(id, func(job *Job) {
		job.Status = JobSucceeded
		job.UpstreamStatus = status
		job.ResponseBody = append([]byte(nil), body...)
	})
}

func (s *JobStore) Fail(id string, status int, body []byte, code, message string, retryable bool) error {
	return s.finish(id, func(job *Job) {
		job.Status = JobFailed
		job.UpstreamStatus = status
		job.ResponseBody = append([]byte(nil), body...)
		job.FailureCode = code
		job.FailureMessage = message
		job.Retryable = retryable
	})
}

func (s *JobStore) finish(id string, update func(*Job)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[id]
	if job == nil {
		return os.ErrNotExist
	}
	update(job)
	job.UpdatedAt = s.now().UTC()
	return s.persistLocked(job)
}

func (s *JobStore) Cleanup() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now().UTC()
	for id, job := range s.jobs {
		if job.ExpiresAt.After(now) {
			continue
		}
		delete(s.jobs, id)
		delete(s.byKey, job.OwnerHash+"\x00"+job.IdempotencyKey)
		if err := os.Remove(s.path(job.ID)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func (s *JobStore) load() error {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return fmt.Errorf("read data directory: %w", err)
	}
	now := s.now().UTC()
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.dir, entry.Name()))
		if err != nil {
			return fmt.Errorf("read job %s: %w", entry.Name(), err)
		}
		var job Job
		if err := json.Unmarshal(data, &job); err != nil {
			return fmt.Errorf("decode job %s: %w", entry.Name(), err)
		}
		if !job.ExpiresAt.After(now) {
			_ = os.Remove(filepath.Join(s.dir, entry.Name()))
			continue
		}
		if job.Status == JobRunning {
			job.Status = JobFailed
			job.UpdatedAt = now
			job.FailureCode = "server_restarted"
			job.FailureMessage = "Der Server wurde während des Aufrufs neu gestartet."
			job.Retryable = true
			if err := s.persistLocked(&job); err != nil {
				return err
			}
		}
		s.jobs[job.ID] = &job
		s.byKey[job.OwnerHash+"\x00"+job.IdempotencyKey] = job.ID
	}
	return nil
}

func (s *JobStore) persistLocked(job *Job) error {
	data, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("encode job: %w", err)
	}
	temporary, err := os.CreateTemp(s.dir, ".job-*")
	if err != nil {
		return fmt.Errorf("create temporary job: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryName, s.path(job.ID)); err != nil {
		return fmt.Errorf("replace job: %w", err)
	}
	directory, err := os.Open(s.dir)
	if err != nil {
		return fmt.Errorf("open data directory: %w", err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("sync data directory: %w", err)
	}
	return nil
}

func (s *JobStore) path(id string) string {
	return filepath.Join(s.dir, id+".json")
}

func randomID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate job id: %w", err)
	}
	return hex.EncodeToString(bytes), nil
}

func cloneJob(job *Job) Job {
	copy := *job
	copy.ResponseBody = append([]byte(nil), job.ResponseBody...)
	return copy
}
