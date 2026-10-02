<!-- MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs. -->
# Oracle op modules

One Ruby file per area, each written by the author of that area, plus one module for the scenario tier:

| Module | Ops it answers |
|---|---|
| `domain.rb`, `events.rb`, `expression.rb`, `aggregation.rb`, `pricing.rb`, `periods.rb`, `invoice.rb`, `credit_note.rb`, `wallet.rb`, `progressive.rb`, `alerts.rb`, `api.rb`, `webhook.rb`, `clock.rb` | the unit ops of their area (`<area>.<op>`, catalogue in `reference/vector-format.md` section 8) |
| `system.rb` | the stateful scenario-tier ops `system.reset`, `system.set_clock`, `system.api`, `system.tick` and `system.snapshot` (`reference/scenario-tier.md`), answered by the full application inside the adapter process: REST calls through the real Rack stack, every enqueued job drained after each call, a frozen wall clock, named clock jobs run by `system.tick` |

`oracle_adapter.rb` loads every `*.rb` here in file-name order after its built-ins (`domain.days_between`,
`domain.round`); a module registers handlers with `KitOracle.op("<area>.<op>") { |input, ctx| ...; {output hash} }`
and may replace a built-in.

`system.reset` deletes every row of the oracle database (`$ORACLE_DB`, which must be a `lago_api_test*` database)
and, for store `ch`, every row of the ClickHouse event tables (under `$LAGO_SKILLS_CACHE/k7-state/ch.lock`): use your
own `ORACLE_DB`.

Contract and helpers: `reference/maintainer-oracle.md` section 4. Check a module with
`ORACLE_DB=<your db> python3 scripts/kitrun.py --impl-cmd "scripts/maintainer/oracle.sh adapter" --areas <area>`;
the `system.*` ops are driven by `scripts/scenario-replay.py` (scenario tier) instead of kitrun.
