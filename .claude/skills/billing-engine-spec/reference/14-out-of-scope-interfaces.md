# 14 — Out-of-scope interfaces (BE-IF)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. The kit specifies the billing core; this chapter fixes only the **boundary** of the
parts left out (payment providers, tax providers, accounting/CRM integrations, documents and e-mails, e-invoicing,
dunning, the newer catalogue/quote features, entitlements, administration, licensing, infrastructure): what the core
emits towards them and what it accepts back, so that a rebuild can stub them or plug its own. Nothing here is graded by
unit vectors; every rule is prose-only by construction.

Reading guide: rules are numbered `BE-IF-n`. "Emits" means the core records something or calls out; "accepts" means
an input the core reacts to. Webhook names are those of chapter 12.

<!-- evidence-check: off normative spec; evidence = prose-only interface contracts (no vectors by construction) -->

## 1. Money in and out

- **BE-IF-1** Payment providers. Emits: a payment request for each finalized invoice with a positive total when the customer has a provider (asynchronously, after finalization); provider refunds for refund credit notes (chapter 08); checkout links on request. Accepts: invoice `payment_status` changes (`pending` → `succeeded` | `failed`, through the provider or `PUT /invoices/:id`), which drive the paid amounts, overdue flags, the settlement of paid wallet top-ups (chapter 09) and payment-gated activation (chapter 06); a lost dispute (`invoice.payment_dispute_lost`). Webhooks `invoice.payment_failure`, `payment.*`, `payment_receipt.*`, `payment_request.*`, `wallet_transaction.payment_failure`, `customer.payment_provider_*`, `credit_note.provider_refund_failure` belong to this boundary. A rebuild without providers treats every invoice as paid manually through the API. [vec: none (prose only: payment providers are out of scope)]
- **BE-IF-2** Payment-gated activation (activation rules): a subscription created with activation rules stays `incomplete` behind a gating invoice until the rules are satisfied, expires through the clock (`expire_incomplete_subscriptions`, chapter 13), and ends `active` or `canceled` (webhooks `subscription.incomplete`, `subscription.canceled`). Creating a subscription with a provider authorization requires a Stripe customer (`422 stripe_required`) and a beta flag (`403` otherwise). [vec: none (prose only: depends on payment providers)]
- **BE-IF-3** Tax providers. Emits: a tax computation request per invoice (and per credit note report) when the customer is linked to a tax integration; local taxes are then not computed (chapter 07). Accepts: per-fee tax lines (possibly a whole-invoice exemption code) that are applied as if computed locally, or an error that sets `tax_status` (and the invoice status) to `failed` with an error detail; the clock retries failed invoices whose error mentions a provider API limit every 15 minutes (chapter 13). Webhooks `customer.tax_provider_error`, `fee.tax_provider_error`. [vec: none (prose only: tax providers are out of scope)]
- **BE-IF-4** VAT-number checks (VIES): a pending check behaves like a pending tax computation (the invoice waits); its result arrives as `customer.vies_check`. E-invoicing (billing entities in France and Germany) produces an XML document next to the PDF (`xml_url`). [vec: none (prose only: e-invoicing is out of scope)]

## 2. Integrations, documents, communication

- **BE-IF-5** Accounting and CRM integrations: customers carry `integration_customers` links; invoices, credit notes, payments and subscriptions are synchronised asynchronously after their state changes; failures surface as `customer.accounting_provider_error` / `customer.crm_provider_error` / `integration.provider_error` webhooks and as error details; nothing in the billing computation depends on them. [vec: none (prose only: integrations are out of scope)]
- **BE-IF-6** Documents: finalized invoices and credit notes get a PDF (and, for e-invoicing, XML) generated asynchronously; `file_url` / `xml_url` stay null until then; `invoice.generated` / `credit_note.generated` announce readiness; download endpoints answer an empty `200` and start generation when the document is missing (chapter 11). Invoice custom sections (texts printed on documents) are attached at finalization and do not change amounts. [vec: none (prose only: document rendering is out of scope)]
- **BE-IF-7** E-mails: invoices, credit notes and payment receipts may be e-mailed when the organization's e-mail settings ask for it (`resend_email` re-sends); e-mail delivery never affects billing state. [vec: none (prose only: e-mail is out of scope)]
- **BE-IF-8** Dunning campaigns and payment requests group overdue invoices of a customer into payment reminders (premium); they read invoice payment state and emit `payment_request.*` and `dunning_campaign.finished`. [vec: none (prose only: dunning is out of scope)]

## 3. Features outside the kit

- **BE-IF-9** The newer product catalogue (products, rate cards, plan rate cards, contracts, quotes, orders, order forms) and entitlements/features have their own routes (`/api/v2` product-catalogue paths, `/features`, `/quotes`, `/orders`, …), webhooks (`quote.*`, `order.*`, `order_form.*`, `feature.*`) and record kinds (plan pricing type `product_catalog`, fee type `product`); legacy plans and fees, which the kit specifies, are unaffected. Analytics, daily usage, the data API, activity/API/security logs and AI features are read-only surfaces over billing data. [vec: none (prose only: out of the kit's scope)]
- **BE-IF-10** Administration (memberships, roles, the GraphQL admin API, the web front end): manual webhook retry and webhook logs, API-key management and rotation, organization HMAC-key rotation exist only there. [vec: none (prose only: administration is out of scope)]
- **BE-IF-11** Licensing: a premium licence flag gates premium behaviour (graduated-percentage charge model, per-transaction minimum/maximum, pricing units, charge minimums, progressive billing, alerts, credit notes, adjusted fees, wallet refresh jobs, API permissions) and the organization's premium integrations list enables optional features; the kit passes the flag explicitly (`premium` in op inputs, tag `premium`; RBD-97). [vec: none (prose only: licensing is an input of the premium-tagged vectors, not a behaviour)]

## 4. Infrastructure the core relies on

- **BE-IF-12** Infrastructure contract: a relational database (state and the relational event store); optionally a columnar event store fed by the events-processor (`events-processor-spec`), with a Redis set of subscriptions to refresh drained by the clock (chapter 13 BE-CK-10); an object store for webhook payloads/responses (gzip JSON) and documents; a cache for API keys (one hour), per-key last-used marks and list counts (chapter 11) whose absence disables the wallet-refresh clock (RBD-79); a job system with named queues and a clock process (chapter 13); a Kafka producer for API/activity logs (non-GET requests except event ingestion). A rebuild may substitute each, keeping the behaviours that the chapters attach to them. [vec: none (prose only: infrastructure contract)]

## Provenance (maintainers)

Interface facts read at the pin (not executed: out of scope by construction), cross-checked against the in-scope
chapters that cite this one (06 BE-SP-63, 07 BE-IV-15, 08 BE-CN-22, 11, 12, 13).

| Rules | Reference code @591ae90 |
|---|---|
| BE-IF-1, BE-IF-2 | `$API/app/services/invoices/payments/create_service.rb`, `$API/app/services/invoices/update_service.rb:141`, `$API/app/services/subscriptions/activation_rules`, `$API/app/controllers/api/v1/subscriptions_controller.rb:23-46`, `$API/config/routes.rb:66-74` |
| BE-IF-3, BE-IF-4 | `$API/app/services/invoices/provider_taxes/pull_taxes_and_apply_service.rb:97`, `$API/app/jobs/clock/retry_failed_invoices_job.rb`, `$API/app/services/webhooks/integrations/taxes/error_service.rb`, `$API/app/services/webhooks/customers/vies_check_service.rb` |
| BE-IF-5..8 | `$API/app/jobs/send_webhook_job.rb:19-95`, `$API/app/controllers/api/v1/invoices_controller.rb:60-196`, `$API/app/services/invoices/generate_pdf_service.rb:20` |
| BE-IF-9..11 | `$API/config/routes.rb:35-64`, `$API/config/routes/shared_api.rb:3-15`, `$API/app/models/organization.rb:131-208`, `$API/config/initializers/license.rb:7` |
| BE-IF-12 | `$API/app/models/webhook.rb:14-139`, `$API/clock.rb:55-71`, `$API/clock.rb:209-216`, `$API/app/controllers/concerns/api_loggable.rb:7-25`, `$API/app/services/api_keys/cache_service.rb:17-75` |

Update triggers: a pin bump, a new integration category or webhook family, a change of the payment or tax provider
contracts.
