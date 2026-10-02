// epconf: black-box conformance runner of the events-processor-spec kit skill.
// It does NOT import events-processor: the implementation under test is an external
// process driven through Kafka (kfake on TCP), Redis (miniredis on TCP) and Postgres
// (a scratch database per scenario).
module epconf

go 1.25.0

require (
	github.com/alicebob/miniredis/v2 v2.37.0
	github.com/twmb/franz-go v1.20.5
	github.com/twmb/franz-go/pkg/kadm v1.17.1
	github.com/twmb/franz-go/pkg/kfake v0.0.0-20251123185109-2b5c574e9ddd
	github.com/twmb/franz-go/pkg/kmsg v1.12.0
)

require (
	github.com/klauspost/compress v1.18.1 // indirect
	github.com/pierrec/lz4/v4 v4.1.22 // indirect
	github.com/yuin/gopher-lua v1.1.1 // indirect
	golang.org/x/crypto v0.45.0 // indirect
)
