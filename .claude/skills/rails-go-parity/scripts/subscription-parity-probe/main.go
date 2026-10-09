// subscription-parity-probe: compares subscription resolution for the same event
// across four implementations, on a THROWAWAY Postgres database (created and dropped):
//
//	go_db     REAL models.ApiStore.FetchSubscription (DB mode) + recurring fallback at time.Now()
//	go_cache  REAL cache.SearchSubscriptions (LAGO_USE_MEMORY_CACHE=true mode) + same fallback
//	rails_pp  Rails Events::PostProcessService#subscriptions.first (excludes status incomplete)
//	          then #fallback_subscription (.active.order(started_at: :desc)) for recurring BMs
//	rails_cm  Rails Events::Common#subscription (used by PayInAdvanceService; no status filter)
//
// The Rails SQL is copied from the pinned lago-api (app/services/events/post_process_service.rb
// #subscriptions/#fallback_subscription, app/models/events/common.rb #subscription). Go gets the
// event time through the REAL utils.ToTime; Rails gets the exact instant (BigDecimal parse).
//
// Usage (from .claude/skills/rails-go-parity/scripts; no CGO needed):
//
//	DATABASE_URL=postgres://lago:lago@localhost:5432/lago go run ./subscription-parity-probe
//
// The role in DATABASE_URL must be allowed to CREATE DATABASE. Nothing is written to the
// database named in DATABASE_URL; a scratch database rgp_probe_<pid> is created and dropped
// (also on a setup error after it was created).
// Exit codes: 0 = report printed (divergences are data, not failures); 1 = setup error.
package main

import (
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/getlago/lago/events-processor/cache"
	"github.com/getlago/lago/events-processor/config/database"
	"github.com/getlago/lago/events-processor/models"
	"github.com/getlago/lago/events-processor/utils"
)

const org = "00000000-0000-0000-0000-00000000000a"

type sub struct {
	id, ext   string
	status    int // Rails enum: pending=0 active=1 terminated=2 canceled=3 incomplete=4
	started   string
	terminate string // "" = NULL
}

type scenario struct {
	name      string
	ext       string
	ts        string // event timestamp exactly as the producer sends it
	exact     time.Time
	recurring bool
	note      string
}

func ts(s string) time.Time { t, _ := time.Parse("2006-01-02 15:04:05.999999", s); return t }

var subs = []sub{
	{"00000000-0000-0000-0000-0000000000a1", "ext-subms", 1, "2025-03-03 13:03:29.000500", ""},
	{"00000000-0000-0000-0000-0000000000b1", "ext-float", 1, "2025-03-03 13:03:29.123", ""},
	{"00000000-0000-0000-0000-0000000000c1", "ext-rfc", 1, "2025-03-03 11:00:00", ""},
	{"00000000-0000-0000-0000-0000000000d1", "ext-incomplete", 4, "2025-01-01 00:00:00", ""},
	{"00000000-0000-0000-0000-0000000000e1", "ext-overlap", 2, "2025-01-01 00:00:00", "2025-03-03 13:03:29"},
	{"00000000-0000-0000-0000-0000000000e2", "ext-overlap", 1, "2025-03-03 13:03:29", ""},
}

var scenarios = []scenario{
	{"A sub-ms started_at", "ext-subms", "1741007009.0", ts("2025-03-03 13:03:29"), false,
		"started_at=T+500us, event at T"},
	{"B float ms rounding", "ext-float", "1741007009.123", ts("2025-03-03 13:03:29.123"), false,
		"started_at=T exactly, ts string \"<T>.123\""},
	{"C RFC3339 offset", "ext-rfc", "2025-03-03T12:30:00+02:00", ts("2025-03-03 10:30:00"), false,
		"event 10:30Z sent with +02:00, sub starts 11:00Z"},
	{"D incomplete status", "ext-incomplete", "1741007009.0", ts("2025-03-03 13:03:29"), false,
		"only sub is status=incomplete"},
	{"E overlap tie at T", "ext-overlap", "1741007009.0", ts("2025-03-03 13:03:29"), false,
		"old terminated at T, new started at T"},
	{"F recurring fallback", "ext-incomplete", "1733011200.0", ts("2024-12-01 00:00:00"), true,
		"event before any sub; only sub is incomplete; BM recurring"},
}

const railsWindow = `organization_id = $1 AND external_id = $2 %s
  AND date_trunc('millisecond', started_at::timestamp) <= $3::timestamp
  AND (terminated_at IS NULL OR date_trunc('millisecond', terminated_at::timestamp) >= $3)
  ORDER BY terminated_at DESC NULLS FIRST, started_at DESC LIMIT 1`

func railsFirst(db *sql.DB, ext string, at time.Time, excludeIncomplete bool) string {
	extra := ""
	if excludeIncomplete {
		extra = "AND status <> 4"
	}
	var id string
	// ActiveRecord quotes a UTC Time as 'YYYY-MM-DD HH:MM:SS.ffffff'
	q := "SELECT id::text FROM subscriptions WHERE " + fmt.Sprintf(railsWindow, extra)
	if err := db.QueryRow(q, org, ext, at.UTC().Format("2006-01-02 15:04:05.000000")).Scan(&id); err != nil {
		return ""
	}
	return id
}

func railsFallback(db *sql.DB, ext string) string {
	var id string
	q := `SELECT id::text FROM subscriptions WHERE organization_id = $1 AND external_id = $2 AND status = 1
	      ORDER BY started_at DESC LIMIT 1`
	if err := db.QueryRow(q, org, ext).Scan(&id); err != nil {
		return ""
	}
	return id
}

func short(id string) string {
	if id == "" {
		return "none"
	}
	return id[len(id)-2:]
}

func goResolve(fetch func(time.Time) utils.Result[*models.Subscription], at time.Time, recurring bool) string {
	r := fetch(at)
	if r.Failure() && !r.IsCapturable() && recurring { // enrichment_service.go recurring fallback
		r = fetch(time.Now())
	}
	if r.Failure() {
		if r.IsCapturable() {
			return "ERROR:" + r.ErrorMsg()
		}
		return ""
	}
	return r.Value().ID
}

// dropScratch is set once the scratch database exists; must() calls it before exiting
// because os.Exit skips deferred calls.
var dropScratch func()

func must(err error, what string) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", what, err)
		if dropScratch != nil {
			dropScratch()
		}
		os.Exit(1)
	}
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	base := os.Getenv("DATABASE_URL")
	if base == "" {
		base = "postgres://lago:lago@localhost:5432/lago"
	}
	u, err := url.Parse(base)
	must(err, "parse DATABASE_URL")
	name := fmt.Sprintf("rgp_probe_%d", os.Getpid())

	admin, err := sql.Open("pgx", base)
	must(err, "open admin")
	defer admin.Close()
	_, err = admin.Exec("CREATE DATABASE " + name)
	must(err, "create scratch database")
	dropScratch = func() {
		dropScratch = nil
		_, derr := admin.Exec("DROP DATABASE IF EXISTS " + name + " WITH (FORCE)")
		if derr != nil {
			fmt.Fprintln(os.Stderr, "drop scratch database:", derr)
		} else {
			fmt.Printf("scratch database %s dropped\n", name)
		}
	}
	defer func() {
		if dropScratch != nil {
			dropScratch()
		}
	}()

	su := *u
	su.Path = "/" + name
	scratch, err := sql.Open("pgx", su.String())
	must(err, "open scratch")
	defer scratch.Close()

	// Column types copied from lago-api db/structure.sql (public.subscriptions), subset.
	_, err = scratch.Exec(`CREATE TABLE subscriptions (
	  id uuid PRIMARY KEY, organization_id uuid NOT NULL, external_id varchar NOT NULL,
	  plan_id uuid NOT NULL, status integer NOT NULL,
	  created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now(),
	  started_at timestamp, terminated_at timestamp)`)
	must(err, "create table")

	c, err := cache.NewCache(cache.CacheConfig{})
	must(err, "cache")
	defer c.Close()

	orgID := org
	for _, s := range subs {
		var term any
		if s.terminate != "" {
			term = s.terminate
		}
		_, err = scratch.Exec(`INSERT INTO subscriptions (id, organization_id, external_id, plan_id, status, started_at, terminated_at)
		  VALUES ($1, $2, $3, $1, $4, $5, $6)`, s.id, org, s.ext, s.status, s.started, term)
		must(err, "insert "+s.id)
		m := models.Subscription{ID: s.id, OrganizationID: &orgID, ExternalID: s.ext, PlanID: s.id,
			StartedAt: utils.NewNullTime(ts(s.started))}
		if s.terminate != "" {
			m.TerminatedAt = utils.NewNullTime(ts(s.terminate))
		}
		if r := c.SetSubscription(&m); r.Failure() {
			must(r.Error(), "cache set")
		}
	}

	gdb, err := database.NewConnection(database.DBConfig{Url: su.String(), MaxConns: 2})
	must(err, "events-processor database.NewConnection")
	defer gdb.Close()
	store := models.NewApiStore(gdb)

	var sessTZ string
	_ = scratch.QueryRow("SHOW timezone").Scan(&sessTZ)
	fmt.Printf("subscription-parity-probe: scratch db %s, session TimeZone=%s; ids shown as last 2 hex chars\n", name, sessTZ)
	fmt.Println("scenario\tgo_time\tgo_db\tgo_cache\trails_pp\trails_cm\tverdict\tnote")
	for _, sc := range scenarios {
		tr := utils.ToTime(sc.ts)
		if tr.Failure() {
			must(tr.Error(), "ToTime "+sc.ts)
		}
		gt := tr.Value()
		gdbID := goResolve(func(t time.Time) utils.Result[*models.Subscription] {
			return store.FetchSubscription(org, sc.ext, t)
		}, gt, sc.recurring)
		gcID := goResolve(func(t time.Time) utils.Result[*models.Subscription] {
			return c.SearchSubscriptions(org, sc.ext, t)
		}, gt, sc.recurring)
		pp := railsFirst(scratch, sc.ext, sc.exact, true)
		if pp == "" && sc.recurring {
			pp = railsFallback(scratch, sc.ext)
		}
		cm := railsFirst(scratch, sc.ext, sc.exact, false)
		verdict := "MATCH"
		if gdbID != pp || gcID != pp || gdbID != gcID {
			parts := []string{}
			if gdbID != pp {
				parts = append(parts, "db!=rails")
			}
			if gcID != pp {
				parts = append(parts, "cache!=rails")
			}
			if gdbID != gcID {
				parts = append(parts, "db!=cache")
			}
			verdict = "DIVERGE(" + strings.Join(parts, ",") + ")"
		}
		fmt.Printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sc.name, gt.Format("15:04:05.000Z07:00"),
			short(gdbID), short(gcID), short(pp), short(cm), verdict, sc.note)
	}
}
