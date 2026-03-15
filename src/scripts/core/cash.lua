_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local cash = _G.AchaeadexLedger.Core.Cash or {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function cash.normalize_currency(currency)
  local normalized = string.lower(trim(currency))
  if normalized == "" then
    error("currency must be a non-empty string")
  end
  return normalized
end

local function integer_amount(amount, field_name)
  local value = tonumber(amount)
  if not value or math.floor(value) ~= value then
    error((field_name or "amount") .. " must be an integer")
  end
  return value
end

local function ensure_state(state)
  state.cash_accounts = state.cash_accounts or {}
  state.cash_movements = state.cash_movements or {}
  state.cash_movement_counter = state.cash_movement_counter or 0
end

local function append_movement(state, event_type, currency, amount, opts)
  opts = opts or {}
  ensure_state(state)

  state.cash_movement_counter = state.cash_movement_counter + 1
  table.insert(state.cash_movements, {
    id = state.cash_movement_counter,
    ts = opts.ts,
    event_type = event_type,
    currency = currency,
    amount = amount,
    reason = opts.reason,
    note = opts.note,
    source_event_id = opts.source_event_id
  })
end

function cash.change_balance(state, currency, amount, opts)
  ensure_state(state)

  local normalized_currency = cash.normalize_currency(currency)
  local integer = integer_amount(amount)
  state.cash_accounts[normalized_currency] = (state.cash_accounts[normalized_currency] or 0) + integer

  if integer ~= 0 then
    append_movement(state, opts and opts.event_type or "CASH_ADJUST", normalized_currency, integer, opts)
  end

  return state.cash_accounts[normalized_currency]
end

function cash.init(state, currency, amount, opts)
  local integer = integer_amount(amount)
  if integer < 0 then
    error("amount must be non-negative")
  end

  opts = opts or {}
  opts.event_type = "CASH_INIT"
  return cash.change_balance(state, currency, integer, opts)
end

function cash.adjust(state, currency, amount, opts)
  opts = opts or {}
  opts.event_type = opts.event_type or "CASH_ADJUST"
  return cash.change_balance(state, currency, integer_amount(amount), opts)
end

function cash.convert(state, from_currency, from_amount, to_currency, to_amount, opts)
  opts = opts or {}
  local from_normalized = cash.normalize_currency(from_currency)
  local to_normalized = cash.normalize_currency(to_currency)
  local debit = integer_amount(from_amount, "from_amount")
  local credit = integer_amount(to_amount, "to_amount")

  if debit < 0 or credit < 0 then
    error("conversion amounts must be non-negative")
  end
  if from_normalized == to_normalized then
    error("from_currency and to_currency must differ")
  end

  cash.adjust(state, from_normalized, -debit, {
    event_type = "CURRENCY_CONVERT",
    note = opts.note,
    reason = opts.reason,
    ts = opts.ts,
    source_event_id = opts.source_event_id
  })
  cash.adjust(state, to_normalized, credit, {
    event_type = "CURRENCY_CONVERT",
    note = opts.note,
    reason = opts.reason,
    ts = opts.ts,
    source_event_id = opts.source_event_id
  })

  return {
    from_currency = from_normalized,
    from_balance = state.cash_accounts[from_normalized] or 0,
    to_currency = to_normalized,
    to_balance = state.cash_accounts[to_normalized] or 0
  }
end

function cash.get_balance(state, currency)
  ensure_state(state)
  return state.cash_accounts[cash.normalize_currency(currency)] or 0
end

function cash.list_balances(state)
  ensure_state(state)
  local rows = {}
  for currency, balance in pairs(state.cash_accounts or {}) do
    table.insert(rows, {
      currency = currency,
      balance = balance
    })
  end
  table.sort(rows, function(a, b)
    return tostring(a.currency) < tostring(b.currency)
  end)
  return rows
end

_G.AchaeadexLedger.Core.Cash = cash

return cash