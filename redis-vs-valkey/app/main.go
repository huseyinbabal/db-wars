// Product page backend for Database Wars: Redis vs Valkey. The same binary talks to either server (RESP, go-redis v9).
//
//	KV_ADDR=10.0.0.5:6379 ADDR=10.0.0.6:8000 kvshop           serve
//	KV_ADDR=10.0.0.5:6379 kvshop seed -products 1000000       load products
//
// Every request does plain, unpipelined round trips like a typical app:
//
//	GET  /products/{id}   HGETALL product:{id}, INCR views:{id}, ZINCRBY trending 1 {id}
//	GET  /trending        ZREVRANGE trending 0 9 WITHSCORES, then one pipeline of 10 HMGET name price
//	POST /cart/{user}     HINCRBY cart:{user} {product} 1, EXPIRE cart:{user} 1800
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

var rdb *redis.Client

func main() {
	pool, _ := strconv.Atoi(env("KV_POOL", "600"))
	rdb = redis.NewClient(&redis.Options{Addr: env("KV_ADDR", "127.0.0.1:6379"), PoolSize: pool, MinIdleConns: 50})
	if len(os.Args) > 1 && os.Args[1] == "seed" {
		seed(os.Args[2:])
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := rdb.Ping(r.Context()).Err(); err != nil {
			http.Error(w, err.Error(), 503)
			return
		}
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /debug/pool", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, rdb.PoolStats()) })
	mux.HandleFunc("GET /products/{id}", product)
	mux.HandleFunc("GET /trending", trending)
	mux.HandleFunc("POST /cart/{user}", cart)
	addr := env("ADDR", "127.0.0.1:8000")
	log.Printf("listening on %s, kv %s", addr, env("KV_ADDR", "127.0.0.1:6379"))
	srv := &http.Server{Addr: addr, Handler: mux, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func product(w http.ResponseWriter, r *http.Request) {
	ctx, id := r.Context(), r.PathValue("id")
	p, err := rdb.HGetAll(ctx, "product:"+id).Result()
	if err != nil {
		fail(w, err)
		return
	}
	if len(p) == 0 {
		http.NotFound(w, r)
		return
	}
	views, err := rdb.Incr(ctx, "views:"+id).Result()
	if err != nil {
		fail(w, err)
		return
	}
	if err := rdb.ZIncrBy(ctx, "trending", 1, id).Err(); err != nil {
		fail(w, err)
		return
	}
	p["views"] = strconv.FormatInt(views, 10)
	writeJSON(w, p)
}

func trending(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	top, err := rdb.ZRevRangeWithScores(ctx, "trending", 0, 9).Result()
	if err != nil {
		fail(w, err)
		return
	}
	pipe := rdb.Pipeline()
	cmds := make([]*redis.SliceCmd, len(top))
	for i, z := range top {
		cmds[i] = pipe.HMGet(ctx, "product:"+z.Member.(string), "name", "price")
	}
	if _, err := pipe.Exec(ctx); err != nil && err != redis.Nil {
		fail(w, err)
		return
	}
	out := make([]map[string]any, len(top))
	for i, z := range top {
		v := cmds[i].Val()
		out[i] = map[string]any{"id": z.Member, "score": z.Score, "name": v[0], "price": v[1]}
	}
	writeJSON(w, out)
}

func cart(w http.ResponseWriter, r *http.Request) {
	ctx, key := r.Context(), "cart:"+r.PathValue("user")
	pid := r.URL.Query().Get("product")
	if pid == "" {
		http.Error(w, "product missing", 400)
		return
	}
	n, err := rdb.HIncrBy(ctx, key, pid, 1).Result()
	if err != nil {
		fail(w, err)
		return
	}
	if err := rdb.Expire(ctx, key, 30*time.Minute).Err(); err != nil {
		fail(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
	writeJSON(w, map[string]int64{"qty": n})
}

// seed writes N product hashes of 8 fields each, 1,000 per pipeline.
func seed(args []string) {
	fs := flag.NewFlagSet("seed", flag.ExitOnError)
	n := fs.Int("products", 1000000, "number of products")
	fs.Parse(args)
	ctx := context.Background()
	if err := rdb.FlushAll(ctx).Err(); err != nil {
		log.Fatal(err)
	}
	cats := []string{"books", "games", "music", "garden", "kitchen", "sports", "toys", "tools"}
	t0 := time.Now()
	for i := 1; i <= *n; i += 1000 {
		pipe := rdb.Pipeline()
		for j := i; j < i+1000 && j <= *n; j++ {
			pipe.HSet(ctx, fmt.Sprintf("product:%d", j),
				"name", fmt.Sprintf("Product %d", j),
				"price", fmt.Sprintf("%d.%02d", 5+j%495, j%100),
				"category", cats[j%len(cats)],
				"stock", strconv.Itoa(j%250),
				"rating", fmt.Sprintf("%d.%d", 1+j%5, j%10),
				"brand", fmt.Sprintf("Brand %d", j%300),
				"sku", fmt.Sprintf("SKU-%08d", j),
				"description", "A product used in the Redis vs Valkey load test.")
		}
		if _, err := pipe.Exec(ctx); err != nil {
			log.Fatal(err)
		}
	}
	log.Printf("seeded %d products in %s", *n, time.Since(t0).Round(time.Millisecond))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, err error) {
	http.Error(w, err.Error(), http.StatusInternalServerError)
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
