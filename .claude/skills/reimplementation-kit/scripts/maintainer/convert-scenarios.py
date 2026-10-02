#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""convert-scenarios.py — turn recorder traces (v3/v4) of the reference's scenario specs into kit scenarios.

Usage:
  convert-scenarios.py --records DIR --manifest scenario-manifest.tsv --out DIR [--only REGEX] [--date YYYY-MM-DD]
  convert-scenarios.py --fill DUMPDIR --manifest scenario-manifest.tsv --out DIR [--only REGEX] [--date YYYY-MM-DD]
  convert-scenarios.py --index DIR        rewrite DIR/MANIFEST.md from the scenario files in DIR

  DIR holds the JSON files written by scenario-recorder.rb (KIT_SCENARIO_RECORD_DIR). The manifest selects which
  recorded example becomes which kit scenario (columns below); every selected row whose source example is missing
  or not convertible is reported and skipped. Output: <out>/<kit id>.json (pretty-printed, sorted keys inside
  objects kept in insertion order) plus one line per row on stdout:
    OK <kit id> <bytes compact> | SKIP <kit id> <reason>

Manifest columns (tab-separated, '#' comments): kit_id, source (example id "spec/…_spec.rb[1:2:1]" or, when the
line is unique, "spec/…_spec.rb:LINE"; "authored" for a scenario written in kit form, see --fill), title, rules
(comma list), rbd (comma list), tags (comma list), options (JSON object or '-'), notes ('-' for none).
Options: {"allow": ["service:<Class>", "factory:<name>", "drain", "no_jobs"]} accept those trace steps (the
replay gate then decides), {"compare": {...}} extra compare rules, {"keep": {"subscriptions": true}} keep
snapshot parts that are dropped by default ({"invoice_keys": [...], "fee_keys": [...], "sub_keys": [...]} narrow the
invoice, fee and subscription fields kept and {"invoice_parts": [...]} the embedded collections, to stay within the
size budget), {"snapshots": {"<trace step index>": {"parts": [...], "keep": {...}, "note": "..."}}} inserts an
intermediate snapshot step after that trace step, expecting the recorded state the source saw there (v4 recordings:
the "before" state of the next REST/clock step, replayed at that step's instant, else the final state; parts default
to the final expectation's lists; keep defaults to the row's keep), {"at_override": {"<trace step index>": "<instant>"}} sets a step's clock (a source step that ran
on the moving wall clock crossed a second boundary), {"bind_where": {"<trace step index>": {...}}} replaces the generated
selector of the object an api step refers to, {"step_expect": [indices]} keep response expectations of those api
steps, {"drop_steps": [indices]}, {"rename": {"old": "new"}} extra renames, {"ticks": {"<helper>": [jobs]}}.

--fill (authored scenarios): a manifest row whose source is "authored" names a scenario written directly in kit form
(setup and steps by hand; --records never overwrites it). Replay it on the reference with
"scenario-replay.py --dump DUMPDIR"; --fill then writes the final "expect" from the dumped final snapshot and the
"expect" of every snapshot step from the snapshot that step received (only the lists the step's draft expect names),
normalised exactly like a recorded final state; evidence = EXECUTED by replay-on-lago with ref "derived" (plus the
row's notes). The replay gate (replay-on-lago.sh) then accepts or rejects it like any scenario.

Recordings: v4 runs every source example on the recorder's kit clock (no step instant comes from the machine's wall
clock; a fractional-second instant within two days of the recording's real time is rejected as a leak); v3
recordings are still read.

What the conversion does (reference/scenario-tier.md sections 2-8 describe the result, not this code):
  * tenant settings from the recorded billing entity (numbering prefix forced to ORG-0001), premium, store;
  * factory-made catalogue (given) -> REST v1 create bodies in setup (taxes, metrics, add-ons, coupons, plans,
    customers), Faker noise dropped, random codes/ids renamed to stable readable names;
  * REST calls -> api steps; clock helpers -> tick steps; recorded ids -> {{var}} via setup auto-captures, step
    captures (id first seen in an earlier response) or binds (objects only visible in a snapshot);
  * random hexadecimal transaction ids (SecureRandom in the source) -> trx_<n>, so a re-mint gives the same file;
  * final state -> expect: business fields of invoices, fees, applied taxes, credit notes, wallets, wallet
    transactions (subscriptions on request), volatile fields (ids, timestamps of creation, URLs, counters) dropped.
Exit: 0 (even when rows were skipped), 1 usage, 2 unreadable inputs.
"""
from __future__ import annotations

import argparse
import collections
import copy
import datetime as dt
import glob
import json
import os
import re
import sys

PREFIX = "ORG-0001"
RE_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
RE_RANDOM_CODE = re.compile(r"^[a-z0-9]{10}$")
RE_HEX_TX = re.compile(r"[A-Za-z_]*[0-9a-f]{32}")
TICKS = {"perform_billing": ["billing"], "perform_usage_update": ["usage_update"],
         "perform_invoices_refresh": ["refresh_drafts"], "perform_finalize_refresh": ["finalize_drafts"],
         "perform_wallet_refresh": ["wallet_refresh"], "perform_overdue_balance_update": ["overdue"],
         "recalculate_wallet_balances": ["lifetime_usage", "wallet_refresh"]}
DIRECT_TICKS = {"Clock::TerminateEndedSubscriptionsJob": ["terminate_ended"],
                "Clock::FinalizeInvoicesJob": ["finalize_drafts"],
                "Clock::RefreshDraftInvoicesJob": ["refresh_drafts"],
                "Clock::ActivateSubscriptionsJob": ["activate_subscriptions"],
                "Clock::RefreshWalletsOngoingBalanceJob": ["wallet_refresh"],
                "Clock::RefreshLifetimeUsagesJob": ["lifetime_usage"],
                "Clock::ProcessAllSubscriptionActivitiesJob": ["subscription_activity"],
                "Clock::TerminateWalletsJob": ["terminate_wallets"],
                "Clock::TerminateCouponsJob": ["terminate_coupons"],
                "Clock::MarkInvoicesAsPaymentOverdueJob": ["overdue"],
                "Clock::CreateIntervalWalletTransactionsJob": ["interval_topups"],
                "Clock::SubscriptionsToBeTerminatedJob": ["termination_alerts"]}
LATE_CATALOG = re.compile(r"^(billable_metric|[a-z_]+_billable_metric|charge|[a-z_]+_charge|charge_filter|charge_filter_value|"
                          r"billable_metric_filter|plan|add_on|coupon|coupon_plan|coupon_billable_metric|tax|pricing_unit|"
                          r"applied_pricing_unit|fixed_charge|customer|usage_threshold|commitment)$")
EVENT_MEMBERS = {"transaction_id", "code", "timestamp", "external_subscription_id", "external_customer_id", "properties",
                 "precise_total_amount_cents"}
READONLY_SERVICES = {"Invoices::CustomerUsageService"}
ORG_DEFAULTS = {"timezone": "UTC", "default_currency": "USD", "document_numbering": "per_customer",
                "invoice_grace_period": 0, "net_payment_term": 0, "finalize_zero_amount_invoice": True,
                "premium_integrations": [], "max_wallets": None, "document_locale": "en", "eu_tax_management": False,
                "subscription_invoice_issuing_date_anchor": "next_period_start",
                "subscription_invoice_issuing_date_adjustment": "align_with_finalization_date"}

# ---- snapshot normalisation (what a scenario expectation keeps) ------------------------------------------------
INVOICE_KEYS = ["invoice_type", "status", "payment_status", "number", "issuing_date", "payment_due_date", "currency",
                "fees_amount_cents", "coupons_amount_cents", "progressive_billing_credit_amount_cents",
                "credit_notes_amount_cents", "prepaid_credit_amount_cents", "taxes_amount_cents",
                "sub_total_excluding_taxes_amount_cents", "sub_total_including_taxes_amount_cents",
                "total_amount_cents", "total_due_amount_cents", "voided_at"]
FEE_KEYS = ["item", "external_subscription_id", "pay_in_advance", "invoiceable", "amount_cents", "units",
            "events_count", "taxes_amount_cents", "taxes_rate", "precise_coupons_amount_cents", "from_date", "to_date"]
ITEM_KEYS = ["type", "code", "filters", "grouped_by", "filter_invoice_display_name"]
APPLIED_TAX_KEYS = ["tax_code", "tax_rate", "amount_cents", "fees_amount_cents"]
PERIOD_KEYS = ["external_subscription_id", "subscription_from_datetime", "subscription_to_datetime",
               "charges_from_datetime", "charges_to_datetime", "invoicing_reason"]
CREDIT_KEYS = ["amount_cents", "item", "before_taxes"]
CN_KEYS = ["credit_status", "refund_status", "reason", "currency", "number", "invoice_number", "issuing_date",
           "total_amount_cents", "taxes_amount_cents", "sub_total_excluding_taxes_amount_cents", "balance_amount_cents",
           "credit_amount_cents", "refund_amount_cents", "offset_amount_cents", "coupons_adjustment_amount_cents",
           "taxes_rate"]
CN_ITEM_KEYS = ["amount_cents", "fee"]
WALLET_KEYS = ["status", "currency", "code", "priority", "rate_amount", "credits_balance", "balance_cents",
               "consumed_credits", "consumed_amount_cents", "ongoing_balance_cents", "ongoing_usage_balance_cents",
               "credits_ongoing_balance", "credits_ongoing_usage_balance", "expiration_at", "terminated_at",
               "paid_top_up_max_amount_cents", "paid_top_up_min_amount_cents"]
WT_KEYS = ["status", "transaction_status", "transaction_type", "source", "amount", "credit_amount", "priority"]
SUB_KEYS = ["external_id", "external_customer_id", "plan_code", "status", "billing_time", "subscription_at",
            "started_at", "trial_ended_at", "ending_at", "terminated_at", "canceled_at", "previous_plan_code",
            "next_plan_code", "downgrade_plan_date"]


def pick(obj, keys, drop_null=True):
    out = {}
    for k in keys:
        if k in obj:
            v = obj[k]
            if drop_null and v is None:
                continue
            out[k] = v
    return out


def norm_item(it):
    o = pick(it or {}, ITEM_KEYS)
    if not o.get("grouped_by"):
        o.pop("grouped_by", None)
    if not o.get("filters"):
        o.pop("filters", None)
    return o


def norm_fee(f, multi_sub, keys=None):
    o = pick(f, keys or FEE_KEYS)
    o["item"] = norm_item(f.get("item"))
    if o.get("item", {}).get("type") == "subscription":
        o["item"].pop("code", None)  # the plan code; kept through billing_periods/subscriptions
    if not multi_sub:
        o.pop("external_subscription_id", None)
    if o.get("pay_in_advance") is False:
        o.pop("pay_in_advance")
    if o.get("invoiceable") is True:
        o.pop("invoiceable")
    if is_zero(o.get("precise_coupons_amount_cents")):
        o.pop("precise_coupons_amount_cents")
    if is_zero(o.get("taxes_rate")) and o.get("taxes_amount_cents") == 0:
        o.pop("taxes_rate", None)
    rate_number(o, "taxes_rate")
    return o


def is_zero(v):
    """0, 0.0 or a zero decimal string ("0", "0.0"): the recorder keeps JSON floats, the oracle's snapshot prints
    decimals as strings."""
    if isinstance(v, bool) or v is None:
        return False
    if isinstance(v, (int, float)):
        return v == 0
    return isinstance(v, str) and re.fullmatch(r"-?0(\.0+)?", v) is not None


def norm_invoice(inv, multi_sub, multi_cust, keep=None):
    keep = keep or {}
    o = pick(inv, keep.get("invoice_keys") or INVOICE_KEYS)
    parts = keep.get("invoice_parts") or ["customer", "billing_periods", "fees", "applied_taxes", "credits"]
    if multi_cust and inv.get("customer") and "customer" in parts:
        o["customer"] = {"external_id": inv["customer"].get("external_id")}
    if "billing_periods" in parts:
        bps = [pick(b, PERIOD_KEYS if multi_sub else PERIOD_KEYS[1:]) for b in inv.get("billing_periods") or []]
        if bps:
            o["billing_periods"] = bps
    if "fees" in parts:
        o["fees"] = [norm_fee(f, multi_sub, keep.get("fee_keys")) for f in inv.get("fees") or []]
    if "applied_taxes" in parts:
        ats = [pick(t, APPLIED_TAX_KEYS) for t in inv.get("applied_taxes") or []]
        if ats:
            o["applied_taxes"] = ats
    if "credits" in parts:
        cr = [dict(pick(c, CREDIT_KEYS), item=pick(c.get("item") or {}, ["type", "code"])) for c in inv.get("credits") or []]
        if cr:
            o["credits"] = cr
    return o


def rate_number(o, key):
    """Rates are JSON numbers in the reference's REST representation; the oracle's snapshot prints them as decimal
    strings, so authored (filled) scenarios would otherwise misstate the type."""
    v = o.get(key)
    if isinstance(v, str) and re.fullmatch(r"-?\d+(\.\d+)?", v):
        o[key] = float(v)


def norm_cn(cn):
    o = pick(cn, CN_KEYS)
    rate_number(o, "taxes_rate")
    o["items"] = [{"amount_cents": i.get("amount_cents"),
                   "fee": {"item": norm_item((i.get("fee") or {}).get("item"))}} for i in cn.get("items") or []]
    ats = [pick(t, ["tax_code", "tax_rate", "amount_cents", "base_amount_cents"]) for t in cn.get("applied_taxes") or []]
    if ats:
        o["applied_taxes"] = ats
    return o


SNAPSHOT_PARTS = ["invoices", "credit_notes", "wallets", "wallet_transactions", "fees", "subscriptions"]


def norm_snapshot(fs, keep, parts=None):
    """parts=None: the final expectation (every list but subscriptions, which only keep.subscriptions adds when the
    snapshot has any); parts=[...]: exactly those lists (intermediate snapshot steps)."""
    subs = fs.get("subscriptions") or []
    multi_sub = len(subs) > 1
    custs = {s.get("external_customer_id") for s in subs}
    multi_cust = len(custs) > 1
    want = parts or SNAPSHOT_PARTS[:5] + (["subscriptions"] if keep.get("subscriptions") and subs else [])
    # Every list is asserted, empty ones included: "no credit note was created" is part of the expected behaviour.
    out = {}
    if "invoices" in want:
        out["invoices"] = [norm_invoice(i, multi_sub, multi_cust, keep) for i in fs.get("invoices") or []]
    if "credit_notes" in want:
        out["credit_notes"] = [norm_cn(c) for c in fs.get("credit_notes") or []]
    if "wallets" in want:
        out["wallets"] = [pick(w, WALLET_KEYS) for w in fs.get("wallets") or []]
    if "wallet_transactions" in want:
        out["wallet_transactions"] = [pick(w, WT_KEYS) for w in fs.get("wallet_transactions") or []]
    if "fees" in want:
        out["fees"] = [norm_fee(f, True, keep.get("fee_keys")) for f in fs.get("fees") or []]
    if "subscriptions" in want:
        out["subscriptions"] = [pick(s, keep.get("sub_keys") or SUB_KEYS) for s in subs]
    return out


# ---- response normalisation (step expectations) ----------------------------------------------------------------
DROP_KEYS = {"created_at", "updated_at", "file_url", "xml_url", "web_url", "lago_id", "logo_url", "name",
             "billing_entity_code", "tax_description", "tax_name", "slug", "sequential_id",
             "description", "applicable_invoice_custom_sections", "integration_customers", "error_details",
             "shipping_address", "metadata", "pricing_unit_details", "presentation_breakdowns", "amount_details"}
KEEP_SUFFIX = ("_cents", "units", "_count", "status", "_date", "_datetime", "_rate", "_type", "code", "credits",
               "_balance", "_amount", "_at", "_id")


def norm_response(v, depth=0):
    if isinstance(v, list):
        return [norm_response(x, depth + 1) for x in v]
    if not isinstance(v, dict):
        return v
    out = {}
    for k, x in v.items():
        if k in DROP_KEYS or k.startswith("lago_") or k.endswith("_url"):
            continue
        if k == "invoice_display_name" and "values" not in v:
            continue
        if k.endswith("_id") and not k.startswith("external_"):
            continue
        if k.endswith("_at") and k not in ("terminated_at", "expiration_at", "ending_at", "canceled_at",
                                            "started_at", "subscription_at", "voided_at", "settled_at"):
            continue
        if k.endswith("_count") and k != "events_count":
            continue
        if isinstance(x, (dict, list)):
            nx = norm_response(x, depth + 1)
            if nx in ({}, []) and k not in ("values", "grouped_by", "filters", "charges_usage", "fees", "errors"):
                continue
            out[k] = nx
        elif x is None:
            continue
        else:
            out[k] = x
    return out


# ---- conversion ----------------------------------------------------------------------------------------------
class Converter:
    def __init__(self, rec, row):
        self.rec = rec
        self.row = row
        self.opts = row["options"]
        self.allow = set(self.opts.get("allow") or [])
        self.alias = {}            # recorded string -> replacement (prefixes, random codes, uuid values)
        self.known = {}            # recorded lago_id -> {{var}} text (setup objects)
        self.counters = collections.Counter()
        self.steps_out = []
        self.resp_ids = {}         # uuid -> (out step index, json path)
        self.cap_n = 0
        self.forced_premium = False

    # names ------------------------------------------------------------------------------------------------------
    def new_alias(self, old, kind):
        if old not in self.alias:
            self.counters[kind] += 1
            self.alias[old] = f"{kind}_{self.counters[kind]}"
        return self.alias[old]

    def code(self, c, kind):
        if isinstance(c, str) and RE_RANDOM_CODE.match(c):
            return self.new_alias(c, kind)
        return c

    def check_trace(self):
        bad = []
        for i, s in enumerate(self.rec["steps"]):
            k = s["kind"]
            if k == "service" and s["name"] not in READONLY_SERVICES and f"service:{s['name']}" not in self.allow:
                bad.append(f"step {i} direct service {s['name']}")
            elif k == "factory" and f"factory:{s['name']}" not in self.allow and not (
                    LATE_CATALOG.match(s["name"]) and self.rec.get("catalog_end")):
                bad.append(f"step {i} factory {s['name']} after the first REST call")
            elif k == "clock_direct" and s["job"] not in DIRECT_TICKS:
                bad.append(f"step {i} clock job {s['job']} has no kit tick")
            elif k == "clock" and s["job"] not in TICKS and s["job"] not in (self.opts.get("ticks") or {}):
                bad.append(f"step {i} clock helper {s['job']} has no kit tick")
            elif k == "api" and s.get("perform_jobs") is False and "no_jobs" not in self.allow:
                bad.append(f"step {i} REST call with jobs deferred")
        settings = self.rec.get("settings") or {}
        if (settings.get("billing_entities_count") or 1) > 1 and self.customer_entity() is None:
            bad.append("customers spread over several billing entities")
        if not self.rec.get("final_state"):
            bad.append("no final state")
        real = self.rec.get("recorded_at")
        if real:  # v4: a fractional-second instant near the real recording time can only be the machine's clock
            r = parse_t(real)
            for i, t in [(-1, (self.rec.get("given") or {}).get("t"))] + [(i, s.get("t")) for i, s in enumerate(self.rec["steps"])]:
                if t and parse_t(t).microsecond and abs((parse_t(t) - r).total_seconds()) < 2 * 86400:
                    bad.append(f"step {i} instant {t} is the recording machine's wall clock (leak)")
                    break
        g = self.rec.get("given") or {}
        if g.get("subscriptions") or g.get("wallets"):
            bad.append("factory-made subscriptions or wallets before the first REST call (no REST equivalent)")
        return bad

    def merged_given(self):
        """given + catalogue objects that factories created after the first REST call (from catalog_end)."""
        g = copy.deepcopy(self.rec["given"])
        ce = self.rec.get("catalog_end")
        if not ce or not any(s["kind"] == "factory" for s in self.rec["steps"]):
            return g
        # objects the REST calls of the trace created themselves (they must not be created twice)
        api_ids = set()
        for s in self.rec["steps"]:
            if s["kind"] != "api" or s["method"] not in ("POST", "PUT") or not isinstance(s.get("response"), dict):
                continue
            for root in ("tax", "billable_metric", "add_on", "coupon", "plan", "customer"):
                obj = s["response"].get(root)
                if isinstance(obj, dict):
                    api_ids.add(obj.get("lago_id"))
                    for sub in ("charges", "fixed_charges"):
                        api_ids.update(c.get("lago_id") for c in obj.get(sub) or [] if isinstance(c, dict))
        api_codes = {(s.get("response") or {}).get(r, {}).get(k) for s in self.rec["steps"]
                     if s["kind"] == "api" and isinstance(s.get("response"), dict)
                     for r, k in (("tax", "code"), ("billable_metric", "code"), ("add_on", "code"), ("coupon", "code"),
                                  ("plan", "code"), ("customer", "external_id"))
                     if isinstance((s.get("response") or {}).get(r), dict)}
        for key in ("taxes", "billable_metrics", "add_ons", "coupons", "plans", "customers"):
            have = {o.get("lago_id") for o in g.get(key) or []}
            for o in ce.get(key) or []:
                if o.get("lago_id") in have or o.get("lago_id") in api_ids or o.get("parent_id"):
                    continue  # given already, created by the trace's REST calls, or a per-subscription override
                if (o.get("code") or o.get("external_id")) in api_codes:
                    continue
                g.setdefault(key, []).append(o)
        ce_plans = {p.get("lago_id"): p for p in ce.get("plans") or []}
        for p in g.get("plans") or []:
            cp = ce_plans.get(p.get("lago_id"))
            if not cp:
                continue
            for sub in ("charges", "fixed_charges"):
                have = {c.get("lago_id") for c in p.get(sub) or []}
                for c in cp.get(sub) or []:
                    if c.get("lago_id") not in have and c.get("lago_id") not in api_ids:
                        p.setdefault(sub, []).append(c)
        return g

    def customer_entity(self):
        """Settings of the billing entity all customers belong to, when the tenant has several entities."""
        st = self.rec.get("settings") or {}
        ents = st.get("billing_entities") or {}
        codes = {c.get("billing_entity_code") for c in (self.rec.get("catalog_end") or self.rec["given"]).get("customers") or []}
        if len(codes) == 1:
            code = codes.pop()
            if code in ents:
                return ents[code]
        return None

    def setup(self):
        st = self.rec["settings"]
        g = self.merged_given()
        be = st.get("billing_entity") or {}
        if (st.get("billing_entities_count") or 1) > 1:
            be = dict(self.customer_entity())
            st = dict(st, billing_entity_tax_codes=be.pop("tax_codes", []))
            self.rec["settings"] = st
        org = st.get("organization") or {}
        tenant = {}
        for k, v in be.items():
            if k == "document_number_prefix":
                continue
            if k in ORG_DEFAULTS and ORG_DEFAULTS[k] != v:
                tenant[k] = v
        for k in ("premium_integrations", "max_wallets", "clickhouse_deduplication_enabled"):
            if k in org and ORG_DEFAULTS.get(k, False) != org[k] and org[k] not in (None, [], False):
                tenant[k] = org[k]
        if org.get("document_numbering") and org["document_numbering"] != be.get("document_numbering"):
            tenant.setdefault("document_numbering", org["document_numbering"])
        tenant["document_number_prefix"] = PREFIX
        for p in (be.get("document_number_prefix"), org.get("document_number_prefix")):
            if p:
                self.alias[p] = PREFIX
        out = {"at": z(g["t"]), "organization": tenant, "premium": bool(st.get("premium")), "store": st.get("store", "pg")}
        taxes = [self.tax(t) for t in g.get("taxes") or []]
        bms = [self.metric(b) for b in g.get("billable_metrics") or []]
        add_ons = [self.add_on(a) for a in g.get("add_ons") or []]
        coupons = [self.coupon(c) for c in g.get("coupons") or []]
        plans = [self.plan(p) for p in g.get("plans") or []]
        customers = [self.customer(c) for c in g.get("customers") or []]
        tz = tenant.get("timezone", "UTC")
        for c in customers:
            if c.get("timezone") == tz:
                c.pop("timezone")
        for key, lst in (("taxes", taxes), ("billable_metrics", bms), ("add_ons", add_ons), ("coupons", coupons),
                         ("plans", plans), ("customers", customers)):
            if lst:
                out[key] = lst
        if not out["premium"] and self.needs_premium(plans, customers):
            # These create fields are accepted over REST only with the premium licence (factories bypass it).
            out["premium"] = True
            self.forced_premium = True
        return out

    @staticmethod
    def needs_premium(plans, customers):
        for p in plans:
            if p.get("minimum_commitment") or p.get("usage_thresholds"):
                return True
            for c in p.get("charges") or []:
                if (c.get("min_amount_cents") or c.get("invoiceable") is False or c.get("regroup_paid_fees")
                        or c.get("charge_model") == "graduated_percentage" or c.get("applied_pricing_unit")):
                    return True
        for c in customers:
            if c.get("timezone") or (c.get("billing_configuration") or {}).get("invoice_grace_period") is not None:
                return True
        return False

    def tax(self, t):
        entity_codes = set((self.rec.get("settings") or {}).get("billing_entity_tax_codes") or [])
        original = t["code"]
        code = self.code(original, "tax")
        if RE_UUID.search(code):
            code = self.new_alias(original, "tax")
        self.known[t["lago_id"]] = f"{{{{tax:{code}}}}}"
        o = {"name": t.get("name") if not RE_RANDOM_CODE.match(t.get("name") or "") else code, "code": code,
             "rate": t["rate"]}
        if t.get("applied_to_organization") or original in entity_codes:
            o["applied_to_organization"] = True  # = applied to the tenant's billing entity
        return o

    def metric(self, b):
        code = self.code(b["code"], "metric")
        self.known[b["lago_id"]] = f"{{{{bm:{code}}}}}"
        o = {"name": code, "code": code, "aggregation_type": b["aggregation_type"]}
        for k in ("field_name", "weighted_interval", "rounding_function", "rounding_precision"):
            if b.get(k) not in (None, ""):
                o[k] = b[k]
        if b.get("aggregation_type") == "count_agg":
            o.pop("field_name", None)
        if b.get("recurring"):
            o["recurring"] = True
        if b.get("expression"):
            o["expression"] = b["expression"]
        if b.get("filters"):
            o["filters"] = [{"key": f["key"], "values": f["values"]} for f in b["filters"]]
        return o

    def add_on(self, a):
        code = self.code(a["code"], "add_on")
        self.known[a["lago_id"]] = f"{{{{add_on:{code}}}}}"
        o = {"name": code, "code": code, "amount_cents": a["amount_cents"], "amount_currency": a["amount_currency"]}
        tc = [self.code(t["code"], "tax") for t in a.get("taxes") or []]
        if tc:
            o["tax_codes"] = tc
        # The factory name is Faker noise (a person-like name) that spec helpers copy into later request bodies
        # (one-off invoice lines): replace it everywhere by the add-on code.
        nm = a.get("name")
        if isinstance(nm, str) and " " in nm and len(nm) >= 6 and nm != code:
            self.alias.setdefault(nm, code)
        return o

    def coupon(self, c):
        code = self.code(c["code"], "coupon")
        self.known[c["lago_id"]] = f"{{{{coupon:{code}}}}}"
        o = {"name": code, "code": code}
        for k in ("coupon_type", "amount_cents", "amount_currency", "percentage_rate", "frequency",
                  "frequency_duration", "reusable", "expiration", "expiration_at"):
            if c.get(k) is not None:
                o[k] = c[k]
        at = {}
        if c.get("limited_plans"):
            at["plan_codes"] = [self.code(x, "plan") for x in c.get("plan_codes") or []]
        if c.get("limited_billable_metrics"):
            at["billable_metric_codes"] = [self.code(x, "metric") for x in c.get("billable_metric_codes") or []]
        if at:
            o["applies_to"] = at
        return o

    def plan(self, p):
        code = self.code(p["code"], "plan")
        self.known[p["lago_id"]] = f"{{{{plan:{code}}}}}"
        o = {"name": code, "code": code, "interval": p["interval"], "amount_cents": p["amount_cents"],
             "amount_currency": p["amount_currency"]}
        for k in ("trial_period", "pay_in_advance", "bill_charges_monthly", "bill_fixed_charges_monthly"):
            if p.get(k) not in (None, False) or (k == "pay_in_advance" and p.get(k) is False):
                if p.get(k) is not None:
                    o[k] = p[k]
        if p.get("bill_fixed_charges_monthly") is False:
            o.pop("bill_fixed_charges_monthly", None)
        tc = [self.code(t["code"], "tax") for t in p.get("taxes") or []]
        if tc:
            o["tax_codes"] = tc
        mc = p.get("minimum_commitment")
        if mc:
            m = {"amount_cents": mc["amount_cents"]}
            mtc = [self.code(t["code"], "tax") for t in mc.get("taxes") or []]
            if mtc:
                m["tax_codes"] = mtc
            o["minimum_commitment"] = m
        if p.get("usage_thresholds"):
            # threshold_display_name is factory Faker noise (a person-like name) and never billing-relevant: dropped.
            o["usage_thresholds"] = [pick(u, ["amount_cents", "recurring"]) for u in p["usage_thresholds"]]
        charges = []
        for ch in p.get("charges") or []:
            ccode = self.code(ch["code"], "charge")
            self.known[ch["lago_id"]] = f"{{{{charge:{code}:{ccode}}}}}"
            c = {"code": ccode, "billable_metric_id": self.known.get(ch["lago_billable_metric_id"], ch["lago_billable_metric_id"]),
                 "charge_model": ch["charge_model"]}
            for k in ("pay_in_advance", "prorated", "regroup_paid_fees"):
                if ch.get(k):
                    c[k] = ch[k]
            if ch.get("invoiceable") is False:
                c["invoiceable"] = False
            if ch.get("min_amount_cents"):
                c["min_amount_cents"] = ch["min_amount_cents"]
            if ch.get("accepts_target_wallet"):
                c["accepts_target_wallet"] = True
            c["properties"] = ch.get("properties") or {}
            if ch.get("applied_pricing_unit"):
                c["applied_pricing_unit"] = pick(ch["applied_pricing_unit"], ["code", "conversion_rate"])
            if ch.get("filters"):
                c["filters"] = [{"invoice_display_name": f.get("invoice_display_name"), "properties": f.get("properties") or {},
                                 "values": f.get("values") or {}} for f in ch["filters"]]
                for f in c["filters"]:
                    if f["invoice_display_name"] is None:
                        f.pop("invoice_display_name")
            ctc = [self.code(t["code"], "tax") for t in ch.get("taxes") or []]
            if ctc:
                c["tax_codes"] = ctc
            charges.append(c)
        if charges:
            o["charges"] = charges
        fcs = []
        for fc in p.get("fixed_charges") or []:
            fcode = self.code(fc.get("code"), "fixed_charge")
            self.known[fc["lago_id"]] = f"{{{{fixed_charge:{code}:{fcode}}}}}"
            f = {"code": fcode, "add_on_id": self.known.get(fc.get("lago_add_on_id"), fc.get("lago_add_on_id")),
                 "charge_model": fc["charge_model"], "units": fc.get("units")}
            for k in ("pay_in_advance", "prorated"):
                if fc.get(k):
                    f[k] = fc[k]
            f["properties"] = fc.get("properties") or {}
            ftc = [self.code(t["code"], "tax") for t in fc.get("taxes") or []]
            if ftc:
                f["tax_codes"] = ftc
            fcs.append(f)
        if fcs:
            o["fixed_charges"] = fcs
        return o

    def customer(self, c):
        ext = c["external_id"]
        if RE_UUID.fullmatch(ext or ""):
            ext = self.new_alias(ext, "cust")
        self.known[c["lago_id"]] = f"{{{{customer:{ext}}}}}"
        o = {"external_id": ext}
        for k in ("currency", "timezone", "net_payment_term"):
            if c.get(k) is not None:
                o[k] = c[k]
        if c.get("finalize_zero_amount_invoice") not in (None, "inherit"):
            o["finalize_zero_amount_invoice"] = c["finalize_zero_amount_invoice"]
        bc = {k: v for k, v in (c.get("billing_configuration") or {}).items()
              if k in ("invoice_grace_period", "document_locale", "subscription_invoice_issuing_date_anchor",
                       "subscription_invoice_issuing_date_adjustment") and v is not None}
        if bc:
            o["billing_configuration"] = bc
        tc = [self.code(t["code"], "tax") for t in c.get("taxes") or []]
        if tc:
            o["tax_codes"] = tc
        return o

    # steps ------------------------------------------------------------------------------------------------------
    def state_after(self, i):
        """The recorded state the source saw after trace step i and the clock it was serialised at: the 'before' of
        the next REST/clock step (v4) at that step's instant, else the final state (at the current clock)."""
        for s in self.rec["steps"][i + 1:]:
            if s["kind"] in ("api", "clock", "clock_direct"):
                if "before" not in s:
                    raise ValueError(f"snapshot after trace step {i} needs a v4 recording (no 'before' state)")
                return s["before"], z(s["t"])
        return self.rec["final_state"], None

    def snapshot_step(self, i, spec):
        keep = spec.get("keep") or self.opts.get("keep") or {}
        parts = spec.get("parts") or (SNAPSHOT_PARTS[:5] + (["subscriptions"] if keep.get("subscriptions") else []))
        state, at = self.state_after(i)
        exp = norm_snapshot(state, keep, parts)
        st = {}
        if at and at != self.last_at:  # serialised fields such as downgrade_plan_date depend on "now"
            st["at"] = at
            self.last_at = at
        st.update({"op": "snapshot", "expect": exp})
        rules = set_rules(exp, "")
        if rules:
            st["compare"] = rules
        if spec.get("note"):
            st["note"] = spec["note"]
        return st

    def steps(self):
        out = []
        self.last_at = z(self.rec["given"]["t"])
        drop = set(self.opts.get("drop_steps") or [])
        keep_expect = set(self.opts.get("step_expect") or [])
        snaps = self.opts.get("snapshots") or {}
        for i, s in enumerate(self.rec["steps"]):
            st = None if i in drop or s["kind"] in ("service", "factory") else self.step(i, s, keep_expect)
            if st is not None:
                out.append(st)
            if str(i) in snaps:
                out.append(self.snapshot_step(i, snaps[str(i)]))
        return out

    def step(self, i, s, keep_expect):
        """One trace step -> one kit step (None for a job drain: every kit api step drains already, ST-12)."""
        at = z((self.opts.get("at_override") or {}).get(str(i)) or s["t"])
        st = {}
        if at != self.last_at:
            st["at"] = at
            self.last_at = at
        if s["kind"] == "api":
            st.update({"op": "api", "method": s["method"], "path": s["path"]})
            if s.get("query"):
                st["query"] = s["query"]
            if s.get("body") not in (None, {}) and s["method"] != "GET":
                st["body"] = s["body"]
                ev = st["body"].get("event") if s["path"] == "/api/v1/events" else None
                if isinstance(ev, dict):  # members the API ignores (BE-EV-1) are noise in a kit body
                    st["body"] = dict(st["body"], event={k: v for k, v in ev.items() if k in EVENT_MEMBERS})
                for _path, tx in walk(st["body"]):  # random hex transaction ids (SecureRandom) -> stable names
                    if _path.endswith("transaction_id") and isinstance(tx, str) and RE_HEX_TX.fullmatch(tx):
                        self.new_alias(tx, "trx")
            status = s["status"]
            want_body = s["method"] == "GET" or "estimate" in s["path"] or status >= 400 or i in keep_expect
            if status != 200 or want_body:
                e = {"status": status}
                if want_body and s.get("response") not in (None, "", {}):
                    e["body"] = norm_response(s["response"])
                    rules = set_rules(e["body"], "body")
                    if rules:
                        st["compare"] = rules
                st["expect"] = e
            st["_resp"] = s.get("response")
            st["_src"] = i
        elif s["kind"] == "clock":
            st.update({"op": "tick", "jobs": (self.opts.get("ticks") or {}).get(s["job"]) or TICKS[s["job"]]})
        elif s["kind"] == "clock_direct":
            st.update({"op": "tick", "jobs": DIRECT_TICKS[s["job"]]})
        elif s["kind"] == "drain":
            return None  # the replay gate checks that dropping the drain is equivalent
        return st

    def link_ids(self, steps, final_state):
        """Replace recorded UUIDs in step paths/query/bodies by {{var}} (setup var, capture or bind) or an alias."""
        first_seen = {}
        objs = {}
        for kind, lst in (("invoices", final_state.get("invoices") or []), ("credit_notes", final_state.get("credit_notes") or []),
                          ("wallets", final_state.get("wallets") or []), ("wallet_transactions", final_state.get("wallet_transactions") or []),
                          ("subscriptions", final_state.get("subscriptions") or []), ("fees", final_state.get("fees") or [])):
            for o in lst:
                objs[o.get("lago_id")] = (kind, o)
                if kind == "invoices":
                    for f in o.get("fees") or []:
                        objs[f.get("lago_id")] = ("invoices[*].fees", f)
        for idx, st in enumerate(steps):
            if st.get("op") != "api":
                continue
            binds = {}

            def fix(v, ctx_key=None):
                if isinstance(v, str):
                    def rep(m):
                        u = m.group(0)
                        if u in self.known:
                            return self.known[u]
                        if u in first_seen:
                            j, path = first_seen[u]
                            var = steps[j].setdefault("capture", {})
                            name = next((k for k, p in var.items() if p == path), None)
                            if name is None:
                                self.cap_n += 1
                                name = f"v{self.cap_n}"
                                var[name] = path
                            return "{{" + name + "}}"
                        if u in objs:
                            kind, o = objs[u]
                            name = f"b{len(binds) + 1}_{idx}"
                            over = (self.opts.get("bind_where") or {}).get(str(st.get("_src")))
                            binds[name] = {"from": kind, "where": over or self.selector(kind, o)}
                            return "{{" + name + "}}"
                        kindn = {"transaction_id": "tx", "external_subscription_id": "sub", "external_customer_id": "cust",
                                 "external_id": "ext", "reference": "ref"}.get(ctx_key, "id")
                        return self.new_alias(u, kindn)
                    return RE_UUID.sub(rep, v)
                if isinstance(v, dict):
                    return {k: fix(x, k) for k, x in v.items()}
                if isinstance(v, list):
                    return [fix(x, ctx_key) for x in v]
                return v
            st["path"] = fix(st["path"])
            if "query" in st:
                st["query"] = fix(st["query"])
            if "body" in st:
                st["body"] = fix(st["body"])
            if binds:
                st["bind"] = binds
            for path, val in walk(st.get("_resp")):
                if isinstance(val, str) and RE_UUID.fullmatch(val) and val not in first_seen and path.endswith("lago_id"):
                    first_seen[val] = (idx, path)
        for st in steps:
            st.pop("_resp", None)
            st.pop("_src", None)
        return steps

    def selector(self, kind, o):
        """A where-clause naming object o by attributes that do not change after creation (an invoice's type,
        customer and billing periods; a fee's item), unique in the recorded final state."""
        if kind == "invoices":
            cust = {"customer": {"external_id": (o.get("customer") or {}).get("external_id")}}
            bps = {"billing_periods": [{"subscription_from_datetime": b.get("subscription_from_datetime"),
                                        "subscription_to_datetime": b.get("subscription_to_datetime")}
                                       for b in o.get("billing_periods") or []]}
            base = {"invoice_type": o.get("invoice_type")}
            for extra in ({}, cust, bps, {**cust, **bps}, {"number": o.get("number")}):
                sel = {**base, **extra}
                if self.unique(kind, sel):
                    return sel
            return {**base, **cust, **bps}
        if kind in ("invoices[*].fees", "fees"):
            it = o.get("item") or {}
            sel = {"item": {"type": it.get("type"), "code": it.get("code")}}
            if it.get("filters"):
                sel["item"]["filters"] = it["filters"]
            if kind == "fees" and o.get("external_subscription_id"):
                sel["external_subscription_id"] = o["external_subscription_id"]
            return sel
        if kind == "subscriptions":
            return {"external_id": o.get("external_id")}
        if kind == "wallets":
            return {"code": o.get("code")} if o.get("code") else {"currency": o.get("currency")}
        if kind == "credit_notes":
            return {"number": o.get("number")}
        return {k: o.get(k) for k in ("transaction_type", "transaction_status", "source", "amount") if k in o}

    def unique(self, kind, sel):
        fs = self.rec["final_state"].get(kind) or []
        return sum(1 for o in fs if contains(o, sel)) == 1

    def convert(self):
        bad = self.check_trace()
        if bad:
            return None, "; ".join(bad[:4])
        setup = self.setup()
        steps = self.link_ids(self.steps(), self.rec["final_state"])
        expect = norm_snapshot(self.rec["final_state"], self.opts.get("keep") or {})
        compare = set_rules(expect, "")
        compare.update(self.opts.get("compare") or {})
        for k, v in (self.opts.get("rename") or {}).items():
            self.alias[k] = v
        doc = {"kit_schema": 1, "id": self.row["kit_id"], "area": "scn", "title": self.row["title"],
               "profile": "both", "ruling": "decided", "pair": None, "rules": self.row["rules"], "rbd": self.row["rbd"],
               "tags": self.row["tags"],
               "evidence": {"kind": "EXECUTED", "by": "replay-on-lago", "ref": "$API/" + self.rec["spec"],
                            "pin": "591ae9005110", "runtime": "ruby-4.0.6 (pinned)", "executed_at": self.row["date"]},
               "setup": setup, "steps": steps, "expect": expect}
        if compare:
            doc["compare"] = compare
        if setup["premium"] and "premium" not in doc["tags"]:
            doc["tags"] = doc["tags"] + ["premium"]
        if self.row.get("notes"):
            doc["notes"] = self.row["notes"]
        doc = apply_alias(doc, self.alias, skip_keys={"evidence"})
        return doc, None


def set_rules(v, base):
    """{pattern: set} for every list of objects with more than one element (indices generalised to [*])."""
    rules = {}

    def go(x, path):
        if isinstance(x, list):
            if len(x) > 1 and all(isinstance(y, dict) for y in x):
                rules[path] = {"mode": "set"}
            for y in x:
                go(y, path + "[*]")
        elif isinstance(x, dict):
            for k, y in x.items():
                go(y, f"{path}.{k}" if path else k)
    go(v, base)
    return rules


def contains(actual, sel):
    """Subset match on plain JSON (arrays: same length, element-wise)."""
    if isinstance(sel, dict):
        return isinstance(actual, dict) and all(k in actual and contains(actual[k], v) for k, v in sel.items())
    if isinstance(sel, list):
        return isinstance(actual, list) and len(actual) == len(sel) and all(contains(a, b) for a, b in zip(actual, sel))
    return actual == sel


def walk(v, path=""):
    if isinstance(v, dict):
        for k, x in v.items():
            yield from walk(x, f"{path}.{k}" if path else k)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            yield from walk(x, f"{path}[{i}]")
    else:
        yield path, v


def apply_alias(v, alias, skip_keys=()):
    if not alias:
        return v
    keys = sorted(alias, key=len, reverse=True)
    rx = re.compile("|".join(re.escape(k) for k in keys))

    def go(x, key=None):
        if key in skip_keys:
            return x
        if isinstance(x, str):
            return rx.sub(lambda m: alias[m.group(0)], x)
        if isinstance(x, dict):
            return {go(k) if isinstance(k, str) and k in alias else k: go(y, k) for k, y in x.items()}
        if isinstance(x, list):
            return [go(y) for y in x]
        return x
    return go(v)


def parse_t(t):
    return dt.datetime.fromisoformat(t.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def z(t):
    """Recorder instants (…000000Z) -> shortest UTC form."""
    d = parse_t(t)
    s = d.strftime("%Y-%m-%dT%H:%M:%S")
    if d.microsecond:
        s += ("." + f"{d.microsecond:06d}").rstrip("0")
    return s + "Z"


def read_manifest(path, date):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 8:
                raise SystemExit(f"manifest line {ln}: expected 8 tab-separated columns, got {len(cols)}")
            kid, src, title, rules, rbd, tags, opts, notes = cols[:8]
            rows.append({"kit_id": kid, "source": src, "title": title,
                         "rules": [x for x in rules.split(",") if x and x != "-"],
                         "rbd": [x for x in rbd.split(",") if x and x != "-"],
                         "tags": [x for x in tags.split(",") if x and x != "-"],
                         "options": json.loads(opts) if opts not in ("", "-") else {},
                         "notes": None if notes in ("", "-") else notes, "date": date})
    return rows


def dump_pretty(doc):
    """Readable but compact: top-level keys one per line, setup lists and steps one item per line."""
    parts = []
    for k, v in doc.items():
        if k in ("steps",) and isinstance(v, list):
            inner = ",\n    ".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) for x in v)
            parts.append(f'  "{k}": [\n    {inner}\n  ]')
        elif k == "setup" and isinstance(v, dict):
            inner = ",\n    ".join(f'"{sk}": ' + json.dumps(sv, ensure_ascii=False, separators=(",", ":")) for sk, sv in v.items())
            parts.append(f'  "{k}": {{\n    {inner}\n  }}')
        elif k == "expect" and isinstance(v, dict):
            sub = []
            for ek, ev in v.items():
                if isinstance(ev, list) and not ev:
                    sub.append(f'"{ek}": []')
                elif isinstance(ev, list):
                    items = ",\n      ".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) for x in ev)
                    sub.append(f'"{ek}": [\n      {items}\n    ]')
                else:
                    sub.append(f'"{ek}": ' + json.dumps(ev, ensure_ascii=False, separators=(",", ":")))
            parts.append(f'  "{k}": {{\n    ' + ",\n    ".join(sub) + "\n  }")
        else:
            parts.append(f'  "{k}": ' + json.dumps(v, ensure_ascii=False, separators=(",", ":")))
    return "{\n" + ",\n".join(parts) + "\n}\n"


TOPICS = {"invoice": "invoices, taxes, coupons, numbering, voiding", "credit_note": "credit notes",
          "subscription": "subscription lifecycle and billing periods", "usage": "current usage per charge model / aggregation",
          "pay_in_advance": "pay-in-advance charges and estimates", "commitment": "minimum commitment",
          "fixed_charge": "fixed charges", "wallet": "wallets and prepaid credits", "alert": "usage alerts",
          "lifetime": "lifetime usage / progressive billing", "events": "event ingestion", "plan": "plan edits",
          "store_ch": "columnar event-store variant"}


def write_index(d):
    rows = []
    total = 0
    for f in sorted(glob.glob(os.path.join(d, "scn.*.json"))):
        with open(f, encoding="utf-8") as fh:
            doc = json.load(fh)
        size = len(json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode())
        total += size
        prof = "" if doc.get("profile", "both") == "both" else f" ({doc['profile']} only)"
        rows.append(f"| `{doc['id']}`{prof} | {doc['title']} | {doc['id'].split('.')[1]} | "
                    f"{', '.join(doc.get('rules') or []) or '-'} | {', '.join(doc.get('rbd') or []) or '-'} | "
                    f"{', '.join(doc.get('tags') or []) or '-'} | {len(doc.get('steps') or [])} | {size} |")
    topics = sorted({r.split("|")[3].strip() for r in rows})
    text = ["# Scenario manifest", "",
            "> Licence note: these scenarios record observable behaviour of lago-api (AGPL-3.0) at pin `591ae90`",
            "> (requests, clock ticks and the resulting API representations), replayed on the reference. Behavioural data,",
            "> not source code; see `reimplementation-kit/reference/legal-and-provenance.md`.", "",
            "End-to-end scenarios of the billing engine. Format, replay semantics and grading: "
            "`reimplementation-kit/reference/scenario-tier.md`. Run them with",
            "`python3 reimplementation-kit/scripts/scenario-replay.py --impl-cmd \"<your system adapter>\"`. Every scenario below is",
            "EXECUTED: replayed twice on the reference with identical results and rejected when one expected integer is",
            "changed (mutation check). Sizes are compact-JSON bytes.", "",
            "| Topic | Covers |", "|---|---|"]
    text += [f"| `{t}` | {TOPICS.get(t, '')} |" for t in topics]
    text += ["", f"{len(rows)} scenarios, {total} bytes compact.", "",
             "| Id | Title | Topic | Rules | RBDs | Tags | Steps | Bytes |", "|---|---|---|---|---|---|---|---|"]
    text += rows
    with open(os.path.join(d, "MANIFEST.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(text) + "\n")
    print(f"MANIFEST.md: {len(rows)} scenarios, {total} bytes")
    return 0


def fill(rows, args):
    """Authored scenarios: expectations from a replay dump on the reference (scenario-replay.py --dump)."""
    only = re.compile(args.only) if args.only else None
    rc = 0
    for row in rows:
        if row["source"] != "authored" or (only and not only.search(row["kit_id"])):
            continue
        sid = row["kit_id"]
        path = os.path.join(args.out, sid + ".json")
        dump_path = os.path.join(args.fill, sid + ".replay.json")
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
            with open(dump_path, encoding="utf-8") as fh:
                dump = json.load(fh)
        except (OSError, ValueError) as e:
            print(f"SKIP {sid} {e}")
            rc = 2
            continue
        calls = dump.get("calls") or []
        final = dump.get("final_snapshot")
        if not isinstance(final, dict):
            print(f"SKIP {sid} the dump has no final snapshot (replay error: {(dump.get('diffs') or [''])[0][:200]})")
            rc = 2
            continue
        keep = row["options"].get("keep") or {}
        for k, st in enumerate(doc["steps"]):
            if st.get("op") != "snapshot":
                continue
            snap = next((c["output"] for c in calls if c.get("op") == "snapshot" and c.get("step") == k
                         and c.get("why") == "step"), None)
            if snap is None:
                print(f"SKIP {sid} no snapshot output for step {k} in the dump")
                rc = 2
                break
            parts = list((st.get("expect") or {}).keys()) or None
            st["expect"] = norm_snapshot(snap, keep, parts or SNAPSHOT_PARTS[:5])
            rules = set_rules(st["expect"], "")
            if rules:
                st["compare"] = rules
            else:
                st.pop("compare", None)
        else:
            doc["expect"] = norm_snapshot(final, keep)
            compare = set_rules(doc["expect"], "")
            compare.update(row["options"].get("compare") or {})
            if compare:
                doc["compare"] = compare
            else:
                doc.pop("compare", None)
            for key in ("title", "rules", "rbd", "tags"):
                doc[key] = row[key]
            if doc.get("setup", {}).get("premium") and "premium" not in doc["tags"]:
                doc["tags"] = doc["tags"] + ["premium"]
            ev = doc.setdefault("evidence", {})
            ev.update({"kind": "EXECUTED", "by": "replay-on-lago", "pin": "591ae9005110",
                       "runtime": "ruby-4.0.6 (pinned)", "executed_at": row["date"]})
            ev.setdefault("ref", "derived")
            if row.get("notes"):
                doc["notes"] = row["notes"]
            order = ["kit_schema", "id", "area", "title", "profile", "ruling", "pair", "rules", "rbd", "tags", "evidence",
                     "setup", "steps", "expect", "compare", "notes"]
            doc = {k: doc[k] for k in order if k in doc}
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(dump_pretty(doc))
            print(f"FILLED {sid} {len(json.dumps(doc, separators=(',', ':'), ensure_ascii=False).encode())}")
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--index")
    ap.add_argument("--fill")
    ap.add_argument("--records")
    ap.add_argument("--manifest")
    ap.add_argument("--out")
    ap.add_argument("--only")
    ap.add_argument("--date", default=dt.date.today().isoformat())
    args = ap.parse_args(argv)
    if args.index:
        return write_index(args.index)
    if not ((args.records or args.fill) and args.manifest and args.out):
        ap.error("--records (or --fill), --manifest and --out are required (or --index DIR)")
    try:
        rows = read_manifest(args.manifest, args.date)
    except (OSError, ValueError) as e:
        print(f"cannot read manifest: {e}", file=sys.stderr)
        return 2
    if args.fill:
        return fill(rows, args)
    by_spec = {}
    for f in glob.glob(os.path.join(args.records, "*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        by_spec[d.get("spec")] = d
        by_spec[str(d.get("example_id", "")).removeprefix("./")] = d
    os.makedirs(args.out, exist_ok=True)
    only = re.compile(args.only) if args.only else None
    for row in rows:
        if only and not only.search(row["kit_id"]):
            continue
        if row["source"] == "authored":
            print(f"KEEP {row['kit_id']} authored in kit form (expectations from --fill)")
            continue
        rec = by_spec.get(row["source"])
        if rec is None:
            print(f"SKIP {row['kit_id']} no recording for {row['source']}")
            continue
        if (rec.get("recorded_with") or {}).get("recorder") not in ("v3", "v4"):
            print(f"SKIP {row['kit_id']} recording is not v3/v4")
            continue
        try:
            doc, why = Converter(copy.deepcopy(rec), row).convert()
        except ValueError as e:
            doc, why = None, str(e)
        if doc is None:
            print(f"SKIP {row['kit_id']} {why}")
            continue
        text = dump_pretty(doc)
        with open(os.path.join(args.out, row["kit_id"] + ".json"), "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"OK {row['kit_id']} {len(json.dumps(doc, separators=(',', ':'), ensure_ascii=False).encode())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
