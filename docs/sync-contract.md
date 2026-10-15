# Kaha POS · Server contract v1 (Supabase RPC)

Project: `opensource-pos` · URL `https://cstntybwrrimdlyjucay.supabase.co` · region ap-southeast-1.
All calls need a signed-in Supabase Auth session (`authenticated`). Anonymous calls are refused.
Money is **integer centavos**. Quantities are whole numbers in v1. Times are ISO-8601 UTC; `business_date` is the Asia/Manila date.

## Device lifecycle

| Call | Who | Returns |
| --- | --- | --- |
| `create_enrollment_code_v1(p_branch_id, p_terminal_code)` | owner / manager | `{code, terminal_code, expires_at}`; code is single-use, 24 h |
| `enroll_device_v1(p_code, p_device_name, p_app_version)` | staff assigned to that branch | `{device_id, device_secret, tenant_id, branch_id, terminal_code, invoice_series:{id,prefix,last_issued}}` |
| `revoke_device_v1(p_device_id, p_reason)` | owner / manager | `{device_id, status}` |

`device_secret` is shown **once**. Store it in OS secure storage (Keychain / Keystore), never in SQLite.
A terminal can have one active device. Replacing a device = revoke the old one, enroll a new one; the new device gets a new invoice series (`DEMO-CR-T01-02`), so numbers never collide.

## Bootstrap and pull

`bootstrap_v1(p_device_id, p_device_secret)` → tenant, branch, device, staff, tax_codes, categories, products, variants, barcodes, stock (sellable shelf), invoice_series, open_shift, **cursor**.

`sync_pull_v1(p_device_id, p_device_secret, p_cursor, p_limit = 500)` →
```json
{ "changes": [{ "entity": "product_variants", "id": "uuid", "op": "upsert|delete", "data": { } }],
  "cursor": "opaque", "has_more": true, "server_time": "..." }
```
Apply one page **and** its cursor in a single SQLite transaction. Loop while `has_more`. Treat the cursor as opaque.
Entities: `tax_codes, categories, products, product_variants, product_barcodes, stock` (stock = `{variant_id, qty}` for this branch).

## Push

`sync_push_v1(p_device_id, p_device_secret, p_commands jsonb[])`, at most 100 commands per call, sent in `local_sequence` order.

```json
{ "command_id": "uuid", "schema_version": 1, "type": "sale.complete",
  "aggregate_id": "uuid", "local_sequence": 42, "occurred_at": "…", "payload": { } }
```

Per-command outcome:

| status | meaning | device does |
| --- | --- | --- |
| `applied` | saved now | mark acked, store `result` |
| `duplicate` | already had it (lost reply) | mark acked with `original_status` / `result` |
| `rejected` | permanent problem, kept server-side for review | quarantine, show "Needs review" with `reason` |
| `retry` | temporary (lock/deadlock) | retry with backoff + jitter |

Same `command_id` with a different payload → `rejected`, reason `idempotency_conflict`. Never reuse ids.

### Command payloads (schema_version 1)

**shift.open** `{shift_id, staff_id, opening_float, opened_at, business_date}`

**cash.movement** `{id, shift_id, staff_id, direction: in|out, amount, reason, occurred_at, approved_by?}`; `out` needs an owner/manager in `approved_by`.

**shift.close** `{shift_id, staff_id, reviewer_id, counted_cash, note?, closed_at}`; server computes expected cash and variance; non-zero variance needs `note`.

**sale.complete**
```json
{
  "sale_id": "uuid", "ref": "S-1A2B3C4D", "shift_id": "uuid", "staff_id": "uuid",
  "occurred_at": "…", "business_date": "2026-10-15",
  "invoice_series_id": "uuid", "invoice_number": 1,
  "discount_info": { "type": "pct", "value": 20, "approved_by": "uuid", "reason": "…" },
  "lines": [{ "line_no": 1, "variant_id": "uuid", "sku": "NDL-001", "name": "…", "unit": "pc",
              "unit_price": 1650, "qty": 2, "tax_treatment": "vatable", "tax_rate_bp": 1200,
              "gross": 3300, "discount": 660, "net": 2640, "vat": 283 }],
  "totals": { "gross": 21475, "discount": 4295, "payable": 17180, "vat": 1396,
              "vatable_sales": 11624, "exempt_sales": 4160, "zero_rated_sales": 0, "non_vat_sales": 0 },
  "payments": [
    { "id": "uuid", "method": "ewallet_manual", "amount": 5000, "reference": "10293847", "verified_by": "uuid", "verified_at": "…" },
    { "id": "uuid", "method": "cash", "amount": 12180, "tendered": 50000, "change_given": 37820 } ]
}
```
Server re-checks: `gross = unit_price × qty`, `net = gross − discount`, line VAT = `(net × rate + (10000 + rate)/2) div (10000 + rate)`, all totals, `Σ payments.amount = payable`, cash `tendered − change_given = amount`, manual payments need a ≥4-char reference. Invoice number must be unused in the device's series.
Not rejected, but recorded in `sale_exceptions`: `price_differs` (catalog price changed since) and `oversold` (shelf balance went negative).

## Errors you will see (`reason`)
`device_not_active`, `device_secret_invalid`, `not_assigned_to_this_branch`, `enrollment_code_invalid_or_used`, `terminal_already_has_an_active_device`, `shift_not_found_for_this_device`, `invoice_number_already_used`, `line N: VAT should be X`, `totals_mismatch: …`, `payments_do_not_match_total: …`, `manager_approval_required`, `staff_not_assigned_to_branch`, `unknown_command_type`, `idempotency_conflict`.

---

# Admin and account functions (online only)

All require a signed-in user. Permission named in brackets; owners have every permission.

| Call | Permission | Purpose |
| --- | --- | --- |
| `my_profile_v1()` | any signed-in user | Staff, store, branches, `permissions[]`; or pending `invitations[]` if not in a store |
| `store_create_v1(p_store_name, p_owner_name, p_branch_code, p_branch_name)` | confirmed email, not in a store | New store; caller becomes owner; default tax codes and role permissions |
| `invitation_accept_v1(p_invitation_id)` | confirmed email matching the invite | Join a store |
| `staff_list_v1()` | any staff | Users and pending invites; emails only with [staff.manage] |
| `staff_invite_v1(p_email, p_display_name, p_role, p_branch_ids)` | [staff.manage]; owners only for role owner | Invite by email |
| `staff_invitation_revoke_v1(p_invitation_id)` | [staff.manage] | Cancel an invite |
| `staff_update_v1(p_staff_id, p_display_name, p_role, p_active, p_branch_ids)` | [staff.manage] | Change role, branches, access. Can't change yourself; store keeps ≥1 active owner |
| `role_permissions_set_v1(p_role, p_permissions)` | [settings.manage] (owner only) | What managers / cashiers / inventory staff can do |
| `catalog_admin_list_v1(p_branch_id)` | any staff | Items (incl. archived), categories, tax codes, stock at that branch |
| `item_save_v1(p)` | [catalog.manage] | Create (no `variant_id`) or update an item: name, sku, unit, tax_code_id, category_id, price_centavos, barcodes[] |
| `item_archive_v1(p_variant_id, p_archived)` | [catalog.manage] | Hide from / return to checkout |
| `category_save_v1(p_category_id, p_name)` | [catalog.manage] | Add or rename a category |
| `stock_receive_v1(p_branch_id, p_variant_id, p_qty, p_reference)` | [stock.receive] | Delivery or opening stock |

Permission codes: `checkout.sell, discount.approve, refund.approve, cash.approve, shift.review, catalog.manage, stock.receive, stock.adjust, staff.manage, devices.manage, reports.view, settings.manage` (owner only).
