package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"
)

// Same tables in both databases. Only the auto-increment spelling differs.
func schema() []string {
	auto, ts := "BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY", "TIMESTAMPTZ NOT NULL DEFAULT now()"
	if kind == "mariadb" {
		auto, ts = "BIGINT AUTO_INCREMENT PRIMARY KEY", "TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP"
	}
	return []string{
		"DROP TABLE IF EXISTS order_items", "DROP TABLE IF EXISTS orders", "DROP TABLE IF EXISTS products",
		`CREATE TABLE products (id BIGINT PRIMARY KEY, name VARCHAR(64) NOT NULL, category INT NOT NULL, price_cents INT NOT NULL, stock BIGINT NOT NULL)`,
		`CREATE INDEX products_category ON products (category, id)`,
		fmt.Sprintf(`CREATE TABLE orders (id %s, customer_id BIGINT NOT NULL, total_cents BIGINT NOT NULL, created_at %s)`, auto, ts),
		`CREATE TABLE order_items (order_id BIGINT NOT NULL, product_id BIGINT NOT NULL, qty INT NOT NULL, price_cents INT NOT NULL, PRIMARY KEY (order_id, product_id))`,
	}
}

// series(a, b) is a table with one column n = a..b.
func series(a, b int) string {
	if kind == "mariadb" {
		return fmt.Sprintf("(SELECT seq AS n FROM seq_%d_to_%d) s", a, b)
	}
	return fmt.Sprintf("generate_series(%d::bigint, %d) AS s(n)", a, b) // bigint: n * 7919 overflows int past 271,000
}

// seed fills both databases with the same rows: every value is plain arithmetic on the row number.
func seed(ctx context.Context, products, orders int) error {
	run := func(what, stmt string) error {
		t := time.Now()
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("%s: %w", what, err)
		}
		log.Printf("%-28s %s", what, time.Since(t).Round(time.Millisecond))
		return nil
	}
	for _, s := range schema() {
		if err := run(strings.SplitN(s, "(", 2)[0], s); err != nil {
			return err
		}
	}
	concat := "'product-' || n"
	if kind == "mariadb" {
		concat = "CONCAT('product-', n)"
	}
	if err := run("products", fmt.Sprintf(`INSERT INTO products (id, name, category, price_cents, stock)
		SELECT n, %s, n %% 100, 100 + (n * 37) %% 9900, 1000000000 FROM %s`, concat, series(1, products))); err != nil {
		return err
	}
	const batch = 100000 // keep each transaction small
	p := products
	for a := 1; a <= orders; a += batch {
		b := min(a+batch-1, orders)
		// two items per order: products (n*31 mod p)+1 and (n*17+5 mod p)+1; when they collide the second one moves to the next product
		first, second := fmt.Sprintf("(n * 31) %% %d + 1", p), fmt.Sprintf("(n * 17 + 5) %% %d + 1", p)
		second = fmt.Sprintf("CASE WHEN %s = %s THEN (%s) %% %d + 1 ELSE %s END", second, first, second, p, second)
		price := func(prod string) string { return fmt.Sprintf("(100 + ((%s) * 37) %% 9900)", prod) }
		qty1, qty2 := "(1 + n % 3)", "(1 + n % 2)"
		over := "OVERRIDING SYSTEM VALUE"
		if kind == "mariadb" {
			over = ""
		}
		stmts := []string{
			fmt.Sprintf(`INSERT INTO orders (id, customer_id, total_cents) %s SELECT n, (n * 7919) %% 100000 + 1, %s * %s + %s * %s FROM %s`,
				over, price(first), qty1, price(second), qty2, series(a, b)),
			fmt.Sprintf(`INSERT INTO order_items (order_id, product_id, qty, price_cents) SELECT n, %s, %s, %s FROM %s`, first, qty1, price(first), series(a, b)),
			fmt.Sprintf(`INSERT INTO order_items (order_id, product_id, qty, price_cents) SELECT n, %s, %s, %s FROM %s`, second, qty2, price(second), series(a, b)),
		}
		t := time.Now()
		for _, s := range stmts {
			if _, err := db.ExecContext(ctx, s); err != nil {
				return fmt.Errorf("orders %d..%d: %w", a, b, err)
			}
		}
		log.Printf("orders %8d..%-8d     %s", a, b, time.Since(t).Round(time.Millisecond))
	}
	next := fmt.Sprintf("ALTER TABLE orders ALTER COLUMN id RESTART WITH %d", orders+1)
	if kind == "mariadb" {
		next = fmt.Sprintf("ALTER TABLE orders AUTO_INCREMENT = %d", orders+1)
	}
	if err := run("next order id", next); err != nil {
		return err
	}
	stats := "ANALYZE"
	if kind == "mariadb" {
		stats = "ANALYZE TABLE products, orders, order_items"
	}
	return run("statistics", stats)
}
