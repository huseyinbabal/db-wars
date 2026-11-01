package main

import (
	"context"
	"encoding/json"

	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// pg keeps each order as one jsonb value: orders(id bigint primary key, doc jsonb).
// pgx prepares every query once per connection and reuses it.
type pg struct{ pool *pgxpool.Pool }

func openPG(ctx context.Context, dsn string, maxConns int) (store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns, cfg.MinConns = int32(maxConns), int32(maxConns)
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &pg{pool}, pool.Ping(ctx)
}

func (p *pg) insert(ctx context.Context, o *order) error {
	doc, _ := json.Marshal(o)
	_, err := p.pool.Exec(ctx, "INSERT INTO orders (id, doc) VALUES ($1, $2)", o.ID, string(doc))
	return err
}

func (p *pg) docs(ctx context.Context, sql string, args ...any) ([]order, error) {
	rows, err := p.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []order{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var o order
		if err := json.Unmarshal(raw, &o); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

func (p *pg) get(ctx context.Context, id int64) (*order, error) {
	out, err := p.docs(ctx, "SELECT doc FROM orders WHERE id = $1", id)
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, errNotFound
	}
	return &out[0], nil
}

func (p *pg) byCustomer(ctx context.Context, customerID int64) ([]order, error) {
	return p.docs(ctx, "SELECT doc FROM orders WHERE (doc->'customer'->>'id')::bigint = $1 ORDER BY id DESC LIMIT 10", customerID)
}

func (p *pg) byProduct(ctx context.Context, productID int64) ([]order, error) {
	return p.docs(ctx, "SELECT doc FROM orders WHERE doc->'items' @> $1 LIMIT 10", fmt.Sprintf(`[{"product_id":%d}]`, productID))
}

func (p *pg) setStatus(ctx context.Context, id int64, status string) error {
	tag, err := p.pool.Exec(ctx, "UPDATE orders SET doc = jsonb_set(doc, '{status}', to_jsonb($2::text)) WHERE id = $1", id, status)
	if err == nil && tag.RowsAffected() == 0 {
		return errNotFound
	}
	return err
}

func (p *pg) stats(ctx context.Context, customerID int64) ([]statusStat, error) {
	rows, err := p.pool.Query(ctx, `SELECT doc->>'status', count(*), sum((doc->>'total_cents')::bigint)
		FROM orders WHERE (doc->'customer'->>'id')::bigint = $1 GROUP BY 1 ORDER BY 1`, customerID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (statusStat, error) {
		var s statusStat
		return s, r.Scan(&s.Status, &s.Count, &s.Total)
	})
}

func (p *pg) maxID(ctx context.Context) (int64, error) {
	var id int64
	err := p.pool.QueryRow(ctx, "SELECT coalesce(max(id), 0) FROM orders").Scan(&id)
	return id, err
}

func (p *pg) seed(ctx context.Context, orders, nItems int) error {
	run := func(what, sql string) error {
		t := time.Now()
		if _, err := p.pool.Exec(ctx, sql); err != nil {
			return fmt.Errorf("%s: %w", what, err)
		}
		log.Printf("%-24s %s", what, time.Since(t).Round(time.Millisecond))
		return nil
	}
	if err := run("drop", "DROP TABLE IF EXISTS orders"); err != nil {
		return err
	}
	if err := run("create table", "CREATE TABLE orders (id bigint PRIMARY KEY, doc jsonb NOT NULL)"); err != nil {
		return err
	}
	const batch = 10000
	for a := 1; a <= orders; a += batch {
		b := min(a+batch-1, orders)
		t := time.Now()
		_, err := p.pool.CopyFrom(ctx, pgx.Identifier{"orders"}, []string{"id", "doc"},
			pgx.CopyFromFunc(func() func() ([]any, error) {
				n := int64(a)
				return func() ([]any, error) {
					if n > int64(b) {
						return nil, nil
					}
					o := makeOrder(n, nItems)
					doc, _ := json.Marshal(o)
					n++
					return []any{o.ID, string(doc)}, nil
				}
			}()))
		if err != nil {
			return fmt.Errorf("orders %d..%d: %w", a, b, err)
		}
		if b%100000 == 0 || b == orders {
			log.Printf("orders %8d..%-8d %s", a, b, time.Since(t).Round(time.Millisecond))
		}
	}
	for _, s := range [][2]string{
		{"index customer", "CREATE INDEX orders_customer ON orders (((doc->'customer'->>'id')::bigint), id)"},
		{"index items", "CREATE INDEX orders_items ON orders USING gin ((doc->'items') jsonb_path_ops) WITH (fastupdate = off)"},
		{"vacuum analyze", "VACUUM ANALYZE orders"},
	} {
		if err := run(s[0], s[1]); err != nil {
			return err
		}
	}
	return nil
}
