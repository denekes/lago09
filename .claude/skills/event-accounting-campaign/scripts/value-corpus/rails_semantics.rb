# rails_semantics.rb - recompute the want_value / want_decimal columns of corpus.tsv the way
# lago-api's own enrichment does, with Ruby's json + bigdecimal (the libraries Rails uses).
# Mirrors $API/app/services/events/enrich_service.rb (pinned 591ae90):
#   :59  enriched_event.value = (event.properties || {})[billable_metric.field_name] || 0
#   :81-85 decimal_value(value) = BigDecimal(value.to_s) rescue ArgumentError -> BigDecimal(0)
# Input: one JSON object per line {"id": "...", "event": "<raw event JSON text>"}.
# Output: id <TAB> want_value <TAB> want_decimal.
# Invoked by `value-corpus -ruby`; not a Rails runtime (no ActiveRecord type casting).
require "json"
require "bigdecimal"

def plain(dec)
  dec.to_s("F").sub(/\.0\z/, "")
end

STDIN.each_line do |line|
  c = JSON.parse(line)
  props = JSON.parse(c["event"])["properties"]
  value = (props || {})["amount"] || 0
  dec = begin
    BigDecimal(value.to_s)
  rescue ArgumentError
    BigDecimal(0)
  end
  shown =
    case value
    when Integer, Float then plain(BigDecimal(value.to_s))
    when String then value
    else "n/a"
    end
  puts [c["id"], shown, plain(dec)].join("\t")
end
