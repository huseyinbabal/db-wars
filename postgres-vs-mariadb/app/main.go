// shop: one small order service, two databases. DB_KIND picks postgres or mariadb; the SQL is the same.
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

	_ "github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
)

var (
	db   *sql.DB
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

// stmt prepares each query once and reuses it, on both databases. Without this the MySQL driver
// prepares, executes and closes a statement for every single call, three round trips instead of one.
var stmts sync.Map

func stmt(ctx context.Context, query string) (*sql.Stmt, error) {
	if s, ok := stmts.Load(query); ok {
		return s.(*sql.Stmt), nil
	}
	s, err := db.PrepareContext(ctx, q(query))
	if err != nil {
		return nil, err
	}
	if old, loaded := stmts.LoadOrStore(query, s); loaded {
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
	driver := map[string]string{"postgres": "pgx", "mariadb": "mysql"}[kind]
	if driver == "" {
		log.Fatalf("DB_KIND must be postgres or mariadb, got %q", kind)
	}
	var err error
	if db, err = sql.Open(driver, os.Getenv("DB_DSN")); err != nil {
		log.Fatal(err)
	}
	maxOpen, _ := strconv.Atoi(env("DB_MAX_OPEN", "20"))
	db.SetMaxOpenConns(maxOpen)
	if env("DB_POOL", "on") == "off" { // every request opens and closes its own connection
		db.SetMaxIdleConns(0)
	} else {
		db.SetMaxIdleConns(maxOpen)
	}
	if err = db.Ping(); err != nil {
		log.Fatal(err)
	}
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
		st, err := stmt(ctx, query)
		if err != nil {
			fail(w, err)
			return
		}
		prepared[i] = st
	}
	tx, err := db.BeginTx(ctx, nil)
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
	s := db.Stats()
	fmt.Fprintf(w, "shop_db_open_connections %d\nshop_db_in_use %d\nshop_db_idle %d\nshop_db_wait_count_total %d\nshop_db_wait_seconds_total %f\n",
		s.OpenConnections, s.InUse, s.Idle, s.WaitCount, s.WaitDuration.Seconds())
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
	log.Printf("shop on %s, database %s, pool %s", addr, kind, env("DB_POOL", "on"))
	log.Fatal(http.ListenAndServe(addr, mux))
}
