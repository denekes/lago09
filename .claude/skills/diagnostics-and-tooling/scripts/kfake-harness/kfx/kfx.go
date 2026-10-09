// Package kfx wraps kfake (an in-process Kafka broker from franz-go) with the
// few helpers that events-processor probes need: start a cluster with seeded
// topics, produce, read a topic back to its high watermark, and read a
// consumer group's committed offset.
//
// It has NO dependency on events-processor and does not need CGO.
//
// Version trap (verified 2026-10-01): kfake has no tags. The pseudo-version
// pinned in ../go.mod (franz-go commit 2b5c574e9ddd) requires franz-go v1.20.4,
// so Go's minimal version selection keeps events-processor's franz-go v1.20.5.
// The latest kfake requires franz-go v1.21.x and go 1.26: `go get kfake@latest`
// silently upgrades franz-go under the code you are testing, and pinning
// franz-go back with a replace directive fails to compile with
// "vs.EachSupportedFeature undefined".
//
// Fault injection: Cluster embeds *kfake.Cluster, so callers can use
// kfake's Control / ControlKey to intercept any Kafka request (e.g. fail
// Produce or OffsetCommit). This package deliberately ships no fault matrix.
package kfx

import (
	"context"
	"fmt"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
)

// Cluster is a running in-process Kafka cluster.
type Cluster struct {
	*kfake.Cluster
	Addrs []string // host:port of each broker, reachable over TCP from other processes too
}

// Start starts a one-broker cluster with every topic seeded with `partitions`
// partitions. Extra kfake options (e.g. kfake.Ports(9092)) are appended.
func Start(partitions int32, topics []string, opts ...kfake.Opt) (*Cluster, error) {
	all := []kfake.Opt{kfake.NumBrokers(1)}
	if len(topics) > 0 {
		all = append(all, kfake.SeedTopics(partitions, topics...))
	}
	all = append(all, opts...)
	c, err := kfake.NewCluster(all...)
	if err != nil {
		return nil, fmt.Errorf("kfake.NewCluster: %w", err)
	}
	return &Cluster{Cluster: c, Addrs: c.ListenAddrs()}, nil
}

// Client returns a plain franz-go client seeded with the cluster brokers.
func (c *Cluster) Client(opts ...kgo.Opt) (*kgo.Client, error) {
	return kgo.NewClient(append([]kgo.Opt{kgo.SeedBrokers(c.Addrs...)}, opts...)...)
}

// Produce synchronously produces one record per value to topic (no key).
func (c *Cluster) Produce(ctx context.Context, topic string, values ...[]byte) error {
	cl, err := c.Client()
	if err != nil {
		return err
	}
	defer cl.Close()
	recs := make([]*kgo.Record, 0, len(values))
	for _, v := range values {
		recs = append(recs, &kgo.Record{Topic: topic, Value: v})
	}
	return cl.ProduceSync(ctx, recs...).FirstErr()
}

// ReadAll reads every record of topic from the start up to the high watermark
// observed when it is called. It returns an error if the watermark is not
// reached before timeout.
func (c *Cluster) ReadAll(ctx context.Context, topic string, timeout time.Duration) ([]*kgo.Record, error) {
	adm, err := c.Client()
	if err != nil {
		return nil, err
	}
	defer adm.Close()
	ends, err := kadm.NewClient(adm).ListEndOffsets(ctx, topic)
	if err != nil {
		return nil, fmt.Errorf("ListEndOffsets %s: %w", topic, err)
	}
	want := map[int32]int64{}
	ends.Each(func(o kadm.ListedOffset) {
		if o.Offset > 0 {
			want[o.Partition] = o.Offset
		}
	})
	if len(want) == 0 {
		return nil, nil
	}

	cl, err := c.Client(kgo.ConsumeTopics(topic), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		return nil, err
	}
	defer cl.Close()
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var out []*kgo.Record
	for len(want) > 0 {
		fs := cl.PollFetches(tctx)
		if tctx.Err() != nil {
			return out, fmt.Errorf("ReadAll %s: timeout with %d partition(s) below high watermark", topic, len(want))
		}
		fs.EachRecord(func(r *kgo.Record) {
			out = append(out, r)
			if hw, ok := want[r.Partition]; ok && r.Offset+1 >= hw {
				delete(want, r.Partition)
			}
		})
	}
	return out, nil
}

// Committed returns the committed offset of group on topic/partition, or -1
// when the group has no commit for it.
func (c *Cluster) Committed(ctx context.Context, group, topic string, partition int32) (int64, error) {
	cl, err := c.Client()
	if err != nil {
		return 0, err
	}
	defer cl.Close()
	resp, err := kadm.NewClient(cl).FetchOffsets(ctx, group)
	if err != nil {
		return 0, fmt.Errorf("FetchOffsets %s: %w", group, err)
	}
	o, ok := resp.Lookup(topic, partition)
	if !ok {
		return -1, nil
	}
	if o.Err != nil {
		return 0, o.Err
	}
	return o.At, nil
}

// Groups lists the consumer groups known to the cluster.
func (c *Cluster) Groups(ctx context.Context) ([]string, error) {
	cl, err := c.Client()
	if err != nil {
		return nil, err
	}
	defer cl.Close()
	gs, err := kadm.NewClient(cl).ListGroups(ctx)
	if err != nil {
		return nil, err
	}
	return gs.Groups(), nil
}

// WaitCommitted polls until group's committed offset on topic/partition is
// >= want, or timeout elapses. It returns the last offset seen.
func (c *Cluster) WaitCommitted(ctx context.Context, group, topic string, partition int32, want int64, timeout time.Duration) (int64, error) {
	deadline := time.Now().Add(timeout)
	last := int64(-1)
	for {
		at, err := c.Committed(ctx, group, topic, partition)
		if err == nil {
			last = at
			if at >= want {
				return at, nil
			}
		}
		if time.Now().After(deadline) {
			return last, fmt.Errorf("group %s %s/%d: committed %d, want >= %d after %s", group, topic, partition, last, want, timeout)
		}
		time.Sleep(100 * time.Millisecond)
	}
}
