package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

type fakeStore struct {
	data      map[string]string
	insertErr error
	lookupErr error
}

func (f *fakeStore) insert(_ context.Context, code, url string) error {
	if f.insertErr != nil {
		return f.insertErr
	}
	f.data[code] = url
	return nil
}

func (f *fakeStore) lookup(_ context.Context, code string) (string, error) {
	if f.lookupErr != nil {
		return "", f.lookupErr
	}
	url, ok := f.data[code]
	if !ok {
		return "", pgx.ErrNoRows
	}
	return url, nil
}

func newFake() *fakeStore { return &fakeStore{data: map[string]string{}} }

func do(t *testing.T, h http.Handler, method, target, body string) *http.Response {
	t.Helper()
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Result()
}

func TestHealthzAlways200(t *testing.T) {
	for _, s := range []store{nil, newFake()} {
		resp := do(t, newRouter(s), "GET", "/healthz", "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("healthz with store=%v: got %d, want 200", s, resp.StatusCode)
		}
	}
}

func TestShortenWithoutDB503(t *testing.T) {
	resp := do(t, newRouter(nil), "POST", "/shorten", `{"url":"https://example.com"}`)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("got %d, want 503", resp.StatusCode)
	}
}

func TestRedirectWithoutDB503(t *testing.T) {
	resp := do(t, newRouter(nil), "GET", "/abc", "")
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("got %d, want 503", resp.StatusCode)
	}
}

func TestShortenInvalidJSON400(t *testing.T) {
	resp := do(t, newRouter(newFake()), "POST", "/shorten", `not-json`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
}

func TestShortenInvalidURL400(t *testing.T) {
	resp := do(t, newRouter(newFake()), "POST", "/shorten", `{"url":"not a url"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
}

func TestShortenRejectsNonHTTPScheme(t *testing.T) {
	for _, raw := range []string{
		`{"url":"javascript:alert(1)"}`,
		`{"url":"data:text/html,<script>alert(1)</script>"}`,
		`{"url":"file:///etc/passwd"}`,
		`{"url":"ftp://example.com/x"}`,
	} {
		resp := do(t, newRouter(newFake()), "POST", "/shorten", raw)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("%s: got %d, want 400", raw, resp.StatusCode)
		}
	}
}

func TestShortenRejectsOversizedBody(t *testing.T) {
	big := `{"url":"https://example.com/` + strings.Repeat("a", 8<<10) + `"}`
	resp := do(t, newRouter(newFake()), "POST", "/shorten", big)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
}

func TestShortenThenRedirect(t *testing.T) {
	s := newFake()
	h := newRouter(s)

	resp := do(t, h, "POST", "/shorten", `{"url":"https://example.com"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("shorten: got %d, want 200", resp.StatusCode)
	}
	var out struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Code == "" {
		t.Fatalf("empty code")
	}
	if got := s.data[out.Code]; got != "https://example.com" {
		t.Fatalf("stored url = %q", got)
	}

	resp = do(t, h, "GET", "/"+out.Code, "")
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("redirect: got %d, want 302", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != "https://example.com" {
		t.Fatalf("Location = %q", loc)
	}
}

func TestRedirectUnknown404(t *testing.T) {
	resp := do(t, newRouter(newFake()), "GET", "/missing", "")
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("got %d, want 404", resp.StatusCode)
	}
	_, _ = io.ReadAll(resp.Body)
}
