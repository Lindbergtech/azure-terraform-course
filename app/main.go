// URL shortener — POST /shorten, GET /{code} → 302, GET /healthz.
//
// DATABASE_URL is optional. When unset, /healthz still serves 200 (so this
// container is demoable before the data tier exists in slice 004); /shorten
// and /{code} return 503.
package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"os"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const schema = `CREATE TABLE IF NOT EXISTS codes (
	code TEXT PRIMARY KEY,
	url TEXT NOT NULL,
	created_at TIMESTAMPTZ DEFAULT now()
)`

type store interface {
	insert(ctx context.Context, code, url string) error
	lookup(ctx context.Context, code string) (string, error)
}

type pgStore struct{ pool *pgxpool.Pool }

func (p *pgStore) insert(ctx context.Context, code, target string) error {
	_, err := p.pool.Exec(ctx, "INSERT INTO codes (code, url) VALUES ($1, $2)", code, target)
	return err
}

func (p *pgStore) lookup(ctx context.Context, code string) (string, error) {
	var target string
	err := p.pool.QueryRow(ctx, "SELECT url FROM codes WHERE code = $1", code).Scan(&target)
	return target, err
}

func main() {
	addr := ":8080"
	dbURL := os.Getenv("DATABASE_URL")

	var s store
	if dbURL == "" {
		log.Println("DATABASE_URL not set; /healthz only — /shorten and /{code} return 503.")
	} else {
		pool, err := pgxpool.New(context.Background(), dbURL)
		if err != nil {
			log.Fatalf("pgxpool.New: %v", err)
		}
		defer pool.Close()
		if _, err := pool.Exec(context.Background(), schema); err != nil {
			log.Fatalf("schema init: %v", err)
		}
		s = &pgStore{pool: pool}
	}

	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, newRouter(s)); err != nil {
		log.Fatal(err)
	}
}

func newRouter(s store) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /shorten", func(w http.ResponseWriter, r *http.Request) {
		if s == nil {
			http.Error(w, "database not configured", http.StatusServiceUnavailable)
			return
		}
		// Cap request body so a single oversized POST cannot OOM the container.
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		var body struct {
			URL string `json:"url"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		u, err := url.ParseRequestURI(body.URL)
		if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
			http.Error(w, "invalid url", http.StatusBadRequest)
			return
		}
		code, err := newCode()
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if err := s.insert(r.Context(), code, body.URL); err != nil {
			http.Error(w, "insert failed", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"code": code})
	})
	mux.HandleFunc("GET /{code}", func(w http.ResponseWriter, r *http.Request) {
		if s == nil {
			http.Error(w, "database not configured", http.StatusServiceUnavailable)
			return
		}
		target, err := s.lookup(r.Context(), r.PathValue("code"))
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				http.NotFound(w, r)
				return
			}
			http.Error(w, "lookup failed", http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, target, http.StatusFound)
	})
	return mux
}

func newCode() (string, error) {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, 8)
	for i, c := range b {
		out[i] = alphabet[int(c)%len(alphabet)]
	}
	return string(out), nil
}
