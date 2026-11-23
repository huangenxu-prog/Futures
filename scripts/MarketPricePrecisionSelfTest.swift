import Foundation

assert(MarketPricePrecision.tickDigits(1) == 0)
assert(MarketPricePrecision.tickDigits(5) == 0)
assert(MarketPricePrecision.tickDigits(0.2) == 1)
assert(MarketPricePrecision.tickDigits(0.01) == 2)
assert(MarketPricePrecision.tickDigits(0.005) == 3)
assert(MarketPricePrecision.digits(tick: nil, observations: [5029, 5027, 5031]) == 0)
assert(MarketPricePrecision.digits(tick: nil, observations: [100.25, 100.75]) == 2)
assert(MarketPricePrecision.format(5029, digits: 0).contains("5"))
assert(!MarketPricePrecision.format(5029, digits: 2).contains(".00"))
print("MarketPricePrecision tests passed")
