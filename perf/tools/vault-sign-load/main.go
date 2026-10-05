// vault-sign-load drives Vault's <intermediate>/sign/leaf-cert the way Consul's
// Vault CA provider does, to measure whether a single pooled HTTP/2 connection
// is a bottleneck.
//
// It uses the same client stack as Consul 2.0.1 (hashicorp/vault/api v1.16.0,
// whose DefaultConfig enables HTTP/2 on its transport):
//
//	-conns 0   one shared client: every worker's requests are multiplexed over
//	           the client's pooled connection(s) - what the Consul leader does
//	-conns N   N independent clients, workers spread across them - N separate
//	           connections, like many direct clients behind the NLB
//
// -concurrency workers each send one request at a time (closed loop), like the
// leader's concurrent ConnectCA.Sign RPC handlers. Every request is traced to
// record which TCP connection and which Vault node served it.
//
// Output: one JSON document on stdout (or -out) with throughput, error counts,
// latency percentiles, distinct connections, requests per Vault node and the
// negotiated protocol. Behind a load balancer the endpoints are the balancer's.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http/httptrace"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	vaultapi "github.com/hashicorp/vault/api"
)

type result struct {
	Mode           string             `json:"mode"`
	Conns          int                `json:"conns_requested"`
	Concurrency    int                `json:"concurrency"`
	Duration       string             `json:"duration"`
	Requests       int64              `json:"requests"`
	Errors         int64              `json:"errors"`
	ErrorSamples   []string           `json:"error_samples,omitempty"`
	RPS            float64            `json:"rps"`
	LatencyMs      map[string]float64 `json:"latency_ms"`
	DistinctConns  int                `json:"distinct_connections"`
	// Remote endpoints of the client's connections. Behind the NLB these are the
	// NLB's addresses, not Vault nodes: which Vault node served each request
	// comes from Vault's own metrics (connection-test.sh adds it per step).
	RequestsByEndpoint map[string]int64 `json:"requests_by_endpoint"`
	Endpoints          int              `json:"endpoints"`
	Protocols      map[string]int64   `json:"protocols"`
	StartUnixMs    int64              `json:"start_unix_ms"`
	EndUnixMs      int64              `json:"end_unix_ms"`
}

type stats struct {
	mu        sync.Mutex
	lat       []float64
	conns     map[string]struct{}
	byNode    map[string]int64
	protocols map[string]int64
	errs      []string
	requests  atomic.Int64
	errors    atomic.Int64
}

func main() {
	addr := flag.String("addr", os.Getenv("VAULT_ADDR"), "Vault address")
	token := flag.String("token", os.Getenv("VAULT_TOKEN"), "Vault token")
	cacert := flag.String("cacert", os.Getenv("VAULT_CACERT"), "CA certificate file")
	path := flag.String("path", "connect_dc1_inter/sign/leaf-cert", "sign path")
	csrFile := flag.String("csr", "", "PEM CSR file")
	ttl := flag.String("ttl", "168h", "requested leaf TTL")
	conns := flag.Int("conns", 0, "0 = one shared client (Consul-like); N = N independent clients")
	concurrency := flag.Int("concurrency", 32, "concurrent in-flight requests (workers)")
	warmup := flag.Duration("warmup", 15*time.Second, "warm-up before measuring (not counted)")
	duration := flag.Duration("duration", 60*time.Second, "measured duration")
	nodeMap := flag.String("nodes", "", "comma-separated name=ip pairs to label endpoints (when targeting nodes directly)")
	out := flag.String("out", "", "write JSON here instead of stdout")
	flag.Parse()

	csr, err := os.ReadFile(*csrFile)
	if err != nil {
		fail("read csr: %v", err)
	}
	names := map[string]string{}
	for _, kv := range strings.Split(*nodeMap, ",") {
		if p := strings.SplitN(kv, "=", 2); len(p) == 2 {
			names[p[1]] = p[0]
		}
	}

	newClient := func() *vaultapi.Client {
		cfg := vaultapi.DefaultConfig() // configures HTTP/2 on its own transport
		cfg.Address = *addr
		cfg.MaxRetries = 0 // count errors instead of hiding them behind retries
		cfg.Timeout = 60 * time.Second
		if err := cfg.ConfigureTLS(&vaultapi.TLSConfig{CACert: *cacert}); err != nil {
			fail("tls: %v", err)
		}
		c, err := vaultapi.NewClient(cfg)
		if err != nil {
			fail("client: %v", err)
		}
		c.SetToken(*token)
		return c
	}
	var clients []*vaultapi.Client
	mode := "single-client"
	if *conns <= 0 {
		clients = []*vaultapi.Client{newClient()}
	} else {
		mode = "multi-client"
		for i := 0; i < *conns; i++ {
			clients = append(clients, newClient())
		}
	}

	body := map[string]interface{}{"csr": string(csr), "ttl": *ttl}
	st := &stats{conns: map[string]struct{}{}, byNode: map[string]int64{}, protocols: map[string]int64{}}
	var measuring atomic.Bool

	sign := func(c *vaultapi.Client) {
		var remote, connID string
		trace := &httptrace.ClientTrace{GotConn: func(i httptrace.GotConnInfo) {
			remote = i.Conn.RemoteAddr().String()
			connID = i.Conn.LocalAddr().String() + "->" + remote
		}}
		ctx := httptrace.WithClientTrace(context.Background(), trace)
		req := c.NewRequest("PUT", "/v1/"+*path)
		if err := req.SetJSONBody(body); err != nil {
			fail("body: %v", err)
		}
		t0 := time.Now()
		resp, err := c.RawRequestWithContext(ctx, req)
		ms := float64(time.Since(t0).Microseconds()) / 1000
		proto := "?"
		if resp != nil {
			proto = resp.Proto
			resp.Body.Close()
		}
		if !measuring.Load() {
			return
		}
		st.requests.Add(1)
		host, _, _ := net.SplitHostPort(remote)
		node := host
		if n, ok := names[host]; ok {
			node = n
		}
		st.mu.Lock()
		defer st.mu.Unlock()
		if err != nil {
			st.errors.Add(1)
			if len(st.errs) < 5 {
				st.errs = append(st.errs, err.Error())
			}
			return
		}
		st.lat = append(st.lat, ms)
		if connID != "" {
			st.conns[connID] = struct{}{}
		}
		st.byNode[node]++
		st.protocols[proto]++
	}

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	for w := 0; w < *concurrency; w++ {
		wg.Add(1)
		c := clients[w%len(clients)]
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				sign(c)
			}
		}()
	}
	time.Sleep(*warmup)
	start := time.Now()
	measuring.Store(true)
	time.Sleep(*duration)
	measuring.Store(false)
	end := time.Now()
	cancel()
	wg.Wait()

	sort.Float64s(st.lat)
	pct := func(p float64) float64 {
		if len(st.lat) == 0 {
			return 0
		}
		i := int(p * float64(len(st.lat)-1))
		return st.lat[i]
	}
	sum := 0.0
	for _, v := range st.lat {
		sum += v
	}
	mean := 0.0
	if len(st.lat) > 0 {
		mean = sum / float64(len(st.lat))
	}
	r := result{
		Mode: mode, Conns: *conns, Concurrency: *concurrency, Duration: duration.String(),
		Requests: st.requests.Load(), Errors: st.errors.Load(), ErrorSamples: st.errs,
		RPS: float64(len(st.lat)) / end.Sub(start).Seconds(),
		LatencyMs: map[string]float64{
			"mean": mean, "p50": pct(0.50), "p95": pct(0.95), "p99": pct(0.99), "max": pct(1),
		},
		DistinctConns: len(st.conns), RequestsByEndpoint: st.byNode, Endpoints: len(st.byNode),
		Protocols: st.protocols, StartUnixMs: start.UnixMilli(), EndUnixMs: end.UnixMilli(),
	}
	enc := json.NewEncoder(os.Stdout)
	if *out != "" {
		f, err := os.Create(*out)
		if err != nil {
			fail("out: %v", err)
		}
		defer f.Close()
		enc = json.NewEncoder(f)
	}
	enc.SetIndent("", "  ")
	if err := enc.Encode(r); err != nil {
		fail("encode: %v", err)
	}
}

func fail(format string, a ...interface{}) {
	fmt.Fprintf(os.Stderr, "vault-sign-load: "+format+"\n", a...)
	os.Exit(1)
}
