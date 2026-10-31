// docshop: one order service, two document stores. DB_KIND picks mongo or postgres (one jsonb column).
// Every order is one document: customer, status, total and its items, read and written whole.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

type customer struct {
	ID    int64  `json:"id" bson:"id"`
	Name  string `json:"name" bson:"name"`
	Email string `json:"email" bson:"email"`
	City  string `json:"city" bson:"city"`
}

type item struct {
	ProductID int64  `json:"product_id" bson:"product_id"`
	Name      string `json:"name" bson:"name"`
	Qty       int    `json:"qty" bson:"qty"`
	Price     int    `json:"price_cents" bson:"price_cents"`
}

type order struct {
	ID        int64     `json:"id" bson:"_id"`
	Customer  customer  `json:"customer" bson:"customer"`
	Status    string    `json:"status" bson:"status"`
	Total     int64     `json:"total_cents" bson:"total_cents"`
	CreatedAt time.Time `json:"created_at" bson:"created_at"`
	Items     []item    `json:"items" bson:"items"`
}

type statusStat struct {
	Status string `json:"status" bson:"_id"`
	Count  int64  `json:"count" bson:"count"`
	Total  int64  `json:"total_cents" bson:"total"`
}

var errNotFound = errors.New("not found")

// store is everything the service asks of a database. Both implementations keep the same indexes:
// the order id, (customer id, order id) and the product ids inside items.
type store interface {
	insert(ctx context.Context, o *order) error
	get(ctx context.Context, id int64) (*order, error)
	byCustomer(ctx context.Context, customerID int64) ([]order, error) // latest 10
	byProduct(ctx context.Context, productID int64) ([]order, error)   // any 10 containing it
	setStatus(ctx context.Context, id int64, status string) error
	stats(ctx context.Context, customerID int64) ([]statusStat, error)
	seed(ctx context.Context, orders, items int) error
	maxID(ctx context.Context) (int64, error)
}

var (
	db     store
	nextID atomic.Int64
	items  = 3 // items per new order, ITEMS
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func open(ctx context.Context) {
	pool, _ := strconv.Atoi(env("DB_MAX_OPEN", "100"))
	var err error
	switch kind := env("DB_KIND", "postgres"); kind {
	case "postgres":
		db, err = openPG(ctx, os.Getenv("DB_DSN"), pool)
	case "mongo":
		db, err = openMongo(ctx, os.Getenv("DB_DSN"), pool)
	default:
		log.Fatalf("DB_KIND must be postgres or mongo, got %q", kind)
	}
	if err != nil {
		log.Fatal(err)
	}
}

// makeOrder builds order n from plain arithmetic on n, so both databases get the same documents.
func makeOrder(n int64, nItems int) order {
	c := (n*7919)%100000 + 1
	o := order{
		ID:        n,
		Customer:  customer{ID: c, Name: fmt.Sprintf("Customer %d", c), Email: fmt.Sprintf("customer%d@example.com", c), City: cities[c%int64(len(cities))]},
		Status:    statuses[n%int64(len(statuses))],
		CreatedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(n) * 13 * time.Second),
	}
	for i := 0; i < nItems; i++ {
		p := (n*31+int64(i)*7177)%100000 + 1
		it := item{ProductID: p, Name: fmt.Sprintf("Product %d", p), Qty: 1 + int((n+int64(i))%3), Price: 100 + int((p*37)%9900)}
		o.Items = append(o.Items, it)
		o.Total += int64(it.Qty * it.Price)
	}
	return o
}

var (
	statuses = []string{"paid", "packed", "shipped", "delivered"}
	cities   = []string{"Amsterdam", "Ankara", "Berlin", "Istanbul", "Lisbon", "London", "Madrid", "Paris", "Rome", "Vienna"}
)

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, err error) {
	if errors.Is(err, errNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	http.Error(w, err.Error(), http.StatusInternalServerError)
}

func idOf(r *http.Request) int64 {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id
}

func main() {
	ctx := context.Background()
	if len(os.Args) > 1 && os.Args[1] == "seed" {
		fs := flag.NewFlagSet("seed", flag.ExitOnError)
		orders := fs.Int("orders", 1000000, "number of orders")
		nItems := fs.Int("items", 3, "items per order")
		fs.Parse(os.Args[2:])
		open(ctx)
		if err := db.seed(ctx, *orders, *nItems); err != nil {
			log.Fatal(err)
		}
		return
	}
	open(ctx)
	items, _ = strconv.Atoi(env("ITEMS", "3"))
	last, err := db.maxID(ctx)
	if err != nil {
		log.Fatal(err)
	}
	nextID.Store(last)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /orders", func(w http.ResponseWriter, r *http.Request) {
		o := makeOrder(nextID.Add(1), items)
		o.CreatedAt = time.Now().UTC()
		if err := db.insert(r.Context(), &o); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 201, map[string]any{"id": o.ID, "total_cents": o.Total})
	})
	mux.HandleFunc("GET /orders/{id}", func(w http.ResponseWriter, r *http.Request) {
		o, err := db.get(r.Context(), idOf(r))
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, o)
	})
	mux.HandleFunc("PATCH /orders/{id}/status", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Status string `json:"status"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Status == "" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if err := db.setStatus(r.Context(), idOf(r), in.Status); err != nil {
			fail(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /customers/{id}/orders", func(w http.ResponseWriter, r *http.Request) {
		out, err := db.byCustomer(r.Context(), idOf(r))
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("GET /customers/{id}/stats", func(w http.ResponseWriter, r *http.Request) {
		out, err := db.stats(r.Context(), idOf(r))
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("GET /products/{id}/orders", func(w http.ResponseWriter, r *http.Request) {
		out, err := db.byProduct(r.Context(), idOf(r))
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	addr := env("ADDR", ":8000")
	log.Printf("docshop on %s, database %s, %d items per new order, next id %d", addr, env("DB_KIND", "postgres"), items, last+1)
	log.Fatal(http.ListenAndServe(addr, mux))
}
