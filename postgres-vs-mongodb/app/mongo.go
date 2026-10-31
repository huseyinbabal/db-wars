package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

// mg keeps each order as one BSON document in shop.orders, _id = order id.
type mg struct{ c *mongo.Collection }

func openMongo(ctx context.Context, uri string, maxConns int) (store, error) {
	cl, err := mongo.Connect(options.Client().ApplyURI(uri).SetMaxPoolSize(uint64(maxConns)).SetMinPoolSize(uint64(maxConns)))
	if err != nil {
		return nil, err
	}
	return &mg{cl.Database("shop").Collection("orders")}, cl.Ping(ctx, nil)
}

func (m *mg) insert(ctx context.Context, o *order) error {
	_, err := m.c.InsertOne(ctx, o)
	return err
}

func (m *mg) docs(ctx context.Context, filter any, opts ...options.Lister[options.FindOptions]) ([]order, error) {
	cur, err := m.c.Find(ctx, filter, opts...)
	if err != nil {
		return nil, err
	}
	out := []order{}
	return out, cur.All(ctx, &out)
}

func (m *mg) get(ctx context.Context, id int64) (*order, error) {
	var o order
	err := m.c.FindOne(ctx, bson.D{{Key: "_id", Value: id}}).Decode(&o)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, errNotFound
	}
	return &o, err
}

func (m *mg) byCustomer(ctx context.Context, customerID int64) ([]order, error) {
	return m.docs(ctx, bson.D{{Key: "customer.id", Value: customerID}},
		options.Find().SetSort(bson.D{{Key: "_id", Value: -1}}).SetLimit(10))
}

func (m *mg) byProduct(ctx context.Context, productID int64) ([]order, error) {
	return m.docs(ctx, bson.D{{Key: "items.product_id", Value: productID}}, options.Find().SetLimit(10))
}

func (m *mg) setStatus(ctx context.Context, id int64, status string) error {
	res, err := m.c.UpdateOne(ctx, bson.D{{Key: "_id", Value: id}}, bson.D{{Key: "$set", Value: bson.D{{Key: "status", Value: status}}}})
	if err == nil && res.MatchedCount == 0 {
		return errNotFound
	}
	return err
}

func (m *mg) stats(ctx context.Context, customerID int64) ([]statusStat, error) {
	cur, err := m.c.Aggregate(ctx, mongo.Pipeline{
		{{Key: "$match", Value: bson.D{{Key: "customer.id", Value: customerID}}}},
		{{Key: "$group", Value: bson.D{{Key: "_id", Value: "$status"}, {Key: "count", Value: bson.D{{Key: "$sum", Value: 1}}}, {Key: "total", Value: bson.D{{Key: "$sum", Value: "$total_cents"}}}}}},
		{{Key: "$sort", Value: bson.D{{Key: "_id", Value: 1}}}},
	})
	if err != nil {
		return nil, err
	}
	out := []statusStat{}
	return out, cur.All(ctx, &out)
}

func (m *mg) maxID(ctx context.Context) (int64, error) {
	var o struct {
		ID int64 `bson:"_id"`
	}
	err := m.c.FindOne(ctx, bson.D{}, options.FindOne().SetSort(bson.D{{Key: "_id", Value: -1}}).SetProjection(bson.D{{Key: "_id", Value: 1}})).Decode(&o)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return 0, nil
	}
	return o.ID, err
}

func (m *mg) seed(ctx context.Context, orders, nItems int) error {
	t := time.Now()
	if err := m.c.Drop(ctx); err != nil {
		return err
	}
	const batch = 10000
	for a := 1; a <= orders; a += batch {
		b := min(a+batch-1, orders)
		t := time.Now()
		docs := make([]any, 0, b-a+1)
		for n := a; n <= b; n++ {
			docs = append(docs, makeOrder(int64(n), nItems))
		}
		if _, err := m.c.InsertMany(ctx, docs, options.InsertMany().SetOrdered(false)); err != nil {
			return fmt.Errorf("orders %d..%d: %w", a, b, err)
		}
		if b%100000 == 0 || b == orders {
			log.Printf("orders %8d..%-8d %s", a, b, time.Since(t).Round(time.Millisecond))
		}
	}
	for _, ix := range []mongo.IndexModel{
		{Keys: bson.D{{Key: "customer.id", Value: 1}, {Key: "_id", Value: -1}}},
		{Keys: bson.D{{Key: "items.product_id", Value: 1}}},
	} {
		t := time.Now()
		name, err := m.c.Indexes().CreateOne(ctx, ix)
		if err != nil {
			return err
		}
		log.Printf("%-24s %s", "index "+name, time.Since(t).Round(time.Millisecond))
	}
	log.Printf("%-24s %s", "seed total", time.Since(t).Round(time.Millisecond))
	return nil
}
