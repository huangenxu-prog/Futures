import Foundation

// This module has NO transport or broker credentials. All state is local
// rehearsal state. No automatic matching, live orders or exchange connection.
struct PaperContract: Codable, Equatable, Sendable {
    let symbol:String
    let name:String
    let tick:Double?
    let multiplier:Double?
    let last:Double?
    let bid:Double?
    let ask:Double?

    var isConcreteFuture:Bool {
        let parts = symbol.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 2, ["SHFE","DCE","CZCE","GFEX","INE","CFFEX"].contains(String(parts[0])) else { return false }
        let body = parts[1]
        let prefix = body.prefix { $0.isASCII && $0.isLetter }
        let suffix = body.dropFirst(prefix.count)
        return !prefix.isEmpty && (3...4).contains(suffix.count) && suffix.allSatisfy{$0.isASCII && $0.isNumber}
    }

    var hasMetadata:Bool {
        guard isConcreteFuture,let tick,let multiplier else { return false }
        return tick.isFinite && tick > 0 && multiplier.isFinite && multiplier > 0
    }
}

enum PaperDirection:String,Codable,CaseIterable,Sendable {
    case buy,sell
    var title:String { self == .buy ? "买入" : "卖出" }
}
enum PaperOffset:String,Codable,CaseIterable,Sendable {
    case open,close
    var title:String { self == .open ? "开仓" : "平仓" }
}
enum PaperOrderStatus:String,Codable,Sendable {
    case pending,filled,cancelled
    var title:String {
        switch self {
        case .pending:return "模拟待成交"
        case .filled:return "模拟已成交"
        case .cancelled:return "模拟已撤销"
        }
    }
}
enum PaperPositionSide:String,Codable,Sendable {
    case long,short
    var title:String { self == .long ? "多头" : "空头" }
}

struct PaperOrder:Identifiable,Codable,Equatable,Sendable {
    let id:UUID
    let contract:PaperContract
    let direction:PaperDirection
    let offset:PaperOffset
    let price:Double
    let quantity:Int
    let created:Date
    var status:PaperOrderStatus
    var actionTitle:String { direction.title+offset.title }
    var side:PaperPositionSide {
        (offset == .open ? direction == .buy : direction == .sell) ? .long : .short
    }
}
struct PaperPosition:Identifiable,Codable,Equatable,Sendable {
    let contract:PaperContract
    let side:PaperPositionSide
    var quantity:Int
    var averagePrice:Double
    var reservedMargin:Double
    var id:String { contract.symbol+"/"+side.rawValue }
}
struct PaperFill:Identifiable,Codable,Equatable,Sendable {
    let id:UUID
    let orderID:UUID
    let symbol:String
    let action:String
    let price:Double
    let quantity:Int
    let realized:Double
    let fee:Double
    let time:Date
}
struct PaperFailure:LocalizedError {
    let message:String
    init(_ message:String) { self.message = message }
    var errorDescription:String? { message }
}

struct PaperLedger:Codable,Equatable,Sendable {
    static let initialCapital = 50_000.0
    // Fixed REHEARSAL assumptions only; not broker margin/commission.
    static let marginRate = 0.15
    static let feePerLot = 5.0
    private(set) var orders:[PaperOrder] = []
    private(set) var positions:[PaperPosition] = []
    private(set) var fills:[PaperFill] = []
    private(set) var cash:Double = initialCapital
    var margin:Double { positions.reduce(0){$0+$1.reservedMargin} }
    var frozen:Double { orders.filter{$0.status == .pending}.reduce(0){$0+Self.reserve($1)} }
    var available:Double { cash-margin-frozen }
    var realized:Double { fills.reduce(0){$0+$1.realized} }
    var fees:Double { fills.reduce(0){$0+$1.fee} }

    static func reserve(_ order:PaperOrder)->Double {
        let fee = Double(order.quantity)*feePerLot
        guard order.offset == .open,let multiplier = order.contract.multiplier else { return fee }
        return order.price*Double(order.quantity)*multiplier*marginRate+fee
    }
    func closable(symbol:String,side:PaperPositionSide)->Int {
        let held = positions.first{$0.contract.symbol == symbol && $0.side == side}?.quantity ?? 0
        let reserved = orders.filter{$0.status == .pending && $0.offset == .close && $0.contract.symbol == symbol && $0.side == side}.reduce(0){$0+$1.quantity}
        return max(0,held-reserved)
    }
    @discardableResult mutating func submit(contract:PaperContract,direction:PaperDirection,offset:PaperOffset,price:Double,quantity:Int,now:Date = Date()) throws -> UUID {
        guard contract.hasMetadata,let tick = contract.tick else { throw PaperFailure("请选择具备真实最小价位和合约乘数的具体月份期货合约") }
        guard price.isFinite,price > 0,(1...999).contains(quantity) else { throw PaperFailure("价格或手数无效") }
        let units = price/tick
        guard units.isFinite,units <= 1e12,abs(units-units.rounded()) < 0.000001 else { throw PaperFailure("价格必须符合合约最小变动价位") }
        guard orders.count < 10_000 else { throw PaperFailure("模拟记录已达上限，请重置模拟账户") }
        let order = PaperOrder(id:UUID(),contract:contract,direction:direction,offset:offset,price:units.rounded()*tick,quantity:quantity,created:now,status:.pending)
        if let position = positions.first(where:{$0.contract.symbol == contract.symbol && $0.side == order.side}),
           position.contract.multiplier != contract.multiplier || position.contract.tick != contract.tick {
            throw PaperFailure("合约参数已变化，不能混合计算模拟持仓")
        }
        if offset == .close && quantity > closable(symbol:contract.symbol,side:order.side) { throw PaperFailure("可平手数不足（含已冻结的平仓委托）") }
        guard Self.reserve(order).isFinite,Self.reserve(order) <= available+0.000001 else { throw PaperFailure("模拟可用资金不足") }
        orders.append(order)
        return order.id
    }
    mutating func cancel(_ id:UUID) throws {
        guard let index = orders.firstIndex(where:{$0.id == id && $0.status == .pending}) else { throw PaperFailure("仅可撤销待成交模拟委托") }
        orders[index].status = .cancelled
    }
    // User explicitly requests a simulated fill at the limit price.
    // This is never represented as an actual exchange match.
    mutating func fill(_ id:UUID,now:Date = Date()) throws {
        guard let index = orders.firstIndex(where:{$0.id == id && $0.status == .pending}) else { throw PaperFailure("委托已处理或不存在") }
        let order = orders[index]
        guard let multiplier = order.contract.multiplier else { throw PaperFailure("缺少合约乘数") }
        let qty = Double(order.quantity),fee = qty*Self.feePerLot
        var pnl = 0.0
        let pos = positions.firstIndex{$0.contract.symbol == order.contract.symbol && $0.side == order.side}
        if order.offset == .open {
            let extra = order.price*qty*multiplier*Self.marginRate
            if let pos {
                guard positions[pos].contract.multiplier == order.contract.multiplier && positions[pos].contract.tick == order.contract.tick else { throw PaperFailure("合约参数不一致") }
                let old = positions[pos]
                let total = old.quantity+order.quantity
                positions[pos].averagePrice = (old.averagePrice*Double(old.quantity)+order.price*qty)/Double(total)
                positions[pos].quantity = total
                positions[pos].reservedMargin += extra
            } else {
                positions.append(PaperPosition(contract:order.contract,side:order.side,quantity:order.quantity,averagePrice:order.price,reservedMargin:extra))
            }
        } else {
            guard let pos,positions[pos].quantity >= order.quantity else { throw PaperFailure("模拟持仓不足") }
            let old = positions[pos]
            let change = order.side == .long ? order.price-old.averagePrice : old.averagePrice-order.price
            pnl = change*qty*multiplier
            if old.quantity == order.quantity { positions.remove(at:pos) }
            else {
                positions[pos].quantity -= order.quantity
                positions[pos].reservedMargin *= Double(positions[pos].quantity)/Double(old.quantity)
            }
        }
        cash += pnl-fee
        orders[index].status = .filled
        fills.append(PaperFill(id:UUID(),orderID:id,symbol:order.contract.symbol,action:order.actionTitle,price:order.price,quantity:order.quantity,realized:pnl,fee:fee,time:now))
    }
}
