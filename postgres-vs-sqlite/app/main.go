// shop: one small order service, two databases. DB_KIND picks postgres or sqlite; the SQL is the same.
// The app runs on the same machine as the database in both cases: SQLite is a library inside the process,
// Postgres is reached over its local Unix socket.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	_ "github.com/mattn/go-sqlite3"
)

var (
	db   *sql.DB // reads (and writes, unless SQLITE_WRITERS=1)
	wdb  *sql.DB // writes: the same pool, or a pool of exactly one connection for SQLite
	kind string
)

// q rewrites ? placeholders to $1, $2, ... for Postgres.
func q(s string) string {
	if kind != "postgres" {
		return s
	}
	var b strings.Builder
	n := 0
	for _, c := range s {
		if c == '?' {
			n++
			b.WriteString("$" + strconv.Itoa(n))
		} else {
			b.WriteRune(c)
		}
	}
	return b.String()
}

// stmt prepares each query once per pool and reuses it, on both databases.
type key struct {
	d *sql.DB
	q string
}

var stmts sync.Map

func stmt(ctx context.Context, query string) (*sql.Stmt, error) { return stmtOn(ctx, db, query) }

func stmtOn(ctx context.Context, d *sql.DB, query string) (*sql.Stmt, error) {
	k := key{d, query}
	if s, ok := stmts.Load(k); ok {
		return s.(*sql.Stmt), nil
	}
	s, err := d.PrepareContext(ctx, q(query))
	if err != nil {
		return nil, err
	}
	if old, loaded := stmts.LoadOrStore(k, s); loaded {
		s.Close()
		return old.(*sql.Stmt), nil
	}
	return s, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func open() {
	kind = env("DB_KIND", "postgres")
	driver := map[string]string{"postgres": "pgx", "sqlite": "sqlite3"}[kind]
	if driver == "" {
		log.Fatalf("DB_KIND must be postgres or sqlite, got %q", kind)
	}
	maxOpen, _ := strconv.Atoi(env("DB_MAX_OPEN", "20"))
	db = pool(driver, maxOpen)
	wdb = db
	if kind == "sqlite" && env("SQLITE_WRITERS", "0") == "1" { // SQLite lets one writer in at a time: give writes their own single connection
		wdb = pool(driver, 1)
	}
}

func pool(driver string, n int) *sql.DB {
	d, err := sql.Open(driver, os.Getenv("DB_DSN"))
	if err != nil {
		log.Fatal(err)
	}
	d.SetMaxOpenConns(n)
	d.SetMaxIdleConns(n)
	d.SetConnMaxLifetime(0)
	if err = d.Ping(); err != nil {
		log.Fatal(err)
	}
	return d
}

type product struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Category int    `json:"category"`
	Price    int    `json:"price_cents"`
	Stock    int64  `json:"stock"`
}

type item struct {
	ProductID int64 `json:"product_id"`
	Qty       int   `json:"qty"`
	Price     int   `json:"price_cents,omitempty"`
}

type order struct {
	ID         int64     `json:"id"`
	CustomerID int64     `json:"customer_id"`
	Total      int64     `json:"total_cents"`
	CreatedAt  time.Time `json:"created_at"`
	Items      []item    `json:"items"`
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, err error) {
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	http.Error(w, err.Error(), http.StatusInternalServerError)
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var p product
	st, err := stmt(r.Context(), "SELECT id, name, category, price_cents, stock FROM products WHERE id = ?")
	if err != nil {
		fail(w, err)
		return
	}
	err = st.QueryRowContext(r.Context(), id).
		Scan(&p.ID, &p.Name, &p.Category, &p.Price, &p.Stock)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, 200, p)
}

func listProducts(w http.ResponseWriter, r *http.Request) {
	cat, _ := strconv.Atoi(r.URL.Query().Get("category"))
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	st, err := stmt(r.Context(), "SELECT id, name, category, price_cents, stock FROM products WHERE category = ? AND id > ? ORDER BY id LIMIT 20")
	if err != nil {
		fail(w, err)
		return
	}
	rows, err := st.QueryContext(r.Context(), cat, after)
	if err != nil {
		fail(w, err)
		return
	}
	defer rows.Close()
	out := []product{}
	for rows.Next() {
		var p product
		if err := rows.Scan(&p.ID, &p.Name, &p.Category, &p.Price, &p.Stock); err != nil {
			fail(w, err)
			return
		}
		out = append(out, p)
	}
	writeJSON(w, 200, out)
}

func getOrder(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	st, err := stmt(r.Context(), `SELECT o.id, o.customer_id, o.total_cents, o.created_at, i.product_id, i.qty, i.price_cents
		FROM orders o JOIN order_items i ON i.order_id = o.id WHERE o.id = ?`)
	if err != nil {
		fail(w, err)
		return
	}
	rows, err := st.QueryContext(r.Context(), id)
	if err != nil {
		fail(w, err)
		return
	}
	defer rows.Close()
	var o order
	for rows.Next() {
		var it item
		if err := rows.Scan(&o.ID, &o.CustomerID, &o.Total, &o.CreatedAt, &it.ProductID, &it.Qty, &it.Price); err != nil {
			fail(w, err)
			return
		}
		o.Items = append(o.Items, it)
	}
	if o.ID == 0 {
		fail(w, sql.ErrNoRows)
		return
	}
	writeJSON(w, 200, o)
}

// createOrder: one transaction. Take stock, read the price, write the order and its items.
func createOrder(w http.ResponseWriter, r *http.Request) {
	var in struct {
		CustomerID int64  `json:"customer_id"`
		Items      []item `json:"items"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || len(in.Items) == 0 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	sort.Slice(in.Items, func(a, b int) bool { return in.Items[a].ProductID < in.Items[b].ProductID }) // same lock order for everyone
	ctx := r.Context()
	var prepared [4]*sql.Stmt
	for i, query := range []string{
		"UPDATE products SET stock = stock - ? WHERE id = ?",
		"SELECT price_cents FROM products WHERE id = ?",
		"INSERT INTO orders (customer_id, total_cents) VALUES (?, ?) RETURNING id",
		"INSERT INTO order_items (order_id, product_id, qty, price_cents) VALUES (?, ?, ?, ?)",
	} {
		st, err := stmtOn(ctx, wdb, query)
		if err != nil {
			fail(w, err)
			return
		}
		prepared[i] = st
	}
	tx, err := wdb.BeginTx(ctx, nil)
	if err != nil {
		fail(w, err)
		return
	}
	defer tx.Rollback()
	takeStock, readPrice, addOrder, addItem := tx.StmtContext(ctx, prepared[0]), tx.StmtContext(ctx, prepared[1]), tx.StmtContext(ctx, prepared[2]), tx.StmtContext(ctx, prepared[3])
	var total int64
	for i := range in.Items {
		it := &in.Items[i]
		if _, err := takeStock.ExecContext(ctx, it.Qty, it.ProductID); err != nil {
			fail(w, err)
			return
		}
		if err := readPrice.QueryRowContext(ctx, it.ProductID).Scan(&it.Price); err != nil {
			fail(w, err)
			return
		}
		total += int64(it.Price) * int64(it.Qty)
	}
	var id int64
	if err := addOrder.QueryRowContext(ctx, in.CustomerID, total).Scan(&id); err != nil {
		fail(w, err)
		return
	}
	for _, it := range in.Items {
		if _, err := addItem.ExecContext(ctx, id, it.ProductID, it.Qty, it.Price); err != nil {
			fail(w, err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, 201, map[string]any{"id": id, "total_cents": total})
}

// metrics: the connection pool, in Prometheus text format.
func metrics(w http.ResponseWriter, _ *http.Request) {
	for name, d := range map[string]*sql.DB{"read": db, "write": wdb} {
		s := d.Stats()
		fmt.Fprintf(w, "shop_db_open_connections{pool=%q} %d\nshop_db_in_use{pool=%q} %d\nshop_db_wait_count_total{pool=%q} %d\nshop_db_wait_seconds_total{pool=%q} %f\n",
			name, s.OpenConnections, name, s.InUse, name, s.WaitCount, name, s.WaitDuration.Seconds())
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "seed" {
		fs := flag.NewFlagSet("seed", flag.ExitOnError)
		products := fs.Int("products", 100000, "number of products")
		orders := fs.Int("orders", 1000000, "number of orders")
		fs.Parse(os.Args[2:])
		open()
		if err := seed(context.Background(), *products, *orders); err != nil {
			log.Fatal(err)
		}
		return
	}
	open()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /products/{id}", getProduct)
	mux.HandleFunc("GET /products", listProducts)
	mux.HandleFunc("GET /orders/{id}", getOrder)
	mux.HandleFunc("POST /orders", createOrder)
	mux.HandleFunc("GET /metrics", metrics)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	addr := env("ADDR", ":8000")
	log.Printf("shop on %s, database %s, pool %s, sqlite writers %s", addr, kind, env("DB_MAX_OPEN", "20"), env("SQLITE_WRITERS", "0"))
	log.Fatal(http.ListenAndServe(addr, mux))
}
