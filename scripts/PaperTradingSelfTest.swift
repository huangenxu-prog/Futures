import Foundation
@main
struct PaperTradingSelfTest {
    static func main() throws {
        let c = PaperContract(symbol:"CZCE.SR701",name:"白糖",tick:1,multiplier:10,last:5000,bid:4999,ask:5001)
        var l = PaperLedger()
        precondition(l.cash == 50000 && l.available == 50000)
        precondition(PaperOrder.actionTitle(direction:.buy,offset:.open) == "开多")
        precondition(PaperOrder.actionTitle(direction:.sell,offset:.open) == "开空")
        precondition(PaperOrder.actionTitle(direction:.sell,offset:.close) == "平多")
        precondition(PaperOrder.actionTitle(direction:.buy,offset:.close) == "平空")
        let id = try l.submit(contract:c,direction:.buy,offset:.open,price:5000,quantity:2)
        precondition(l.positions.isEmpty && l.frozen == 15010)
        try l.fill(id)
        precondition(l.cash == 49990 && l.margin == 15000 && l.positions[0].quantity == 2)
        do {try l.fill(id);fatalError("duplicate fill")} catch {}
        let close = try l.submit(contract:c,direction:.sell,offset:.close,price:5100,quantity:1)
        precondition(l.closable(symbol:c.symbol,side:.long) == 1)
        do {_ = try l.submit(contract:c,direction:.sell,offset:.close,price:5100,quantity:2);fatalError("overclose")} catch {}
        try l.fill(close)
        precondition(l.positions[0].quantity == 1 && l.realized == 1000 && l.cash == 50985 && l.margin == 7500)
        let pending = try l.submit(contract:c,direction:.sell,offset:.close,price:5100,quantity:1)
        precondition(l.closable(symbol:c.symbol,side:.long) == 0)
        try l.cancel(pending)
        precondition(l.closable(symbol:c.symbol,side:.long) == 1 && l.frozen == 0)
        do {_ = try l.submit(contract:c,direction:.buy,offset:.open,price:5000.5,quantity:1);fatalError("bad tick")} catch {}
        do {_ = try l.submit(contract:c,direction:.buy,offset:.open,price:5000,quantity:999);fatalError("insufficient margin")} catch {}
        let invalid = PaperContract(symbol:"KQ.m@CZCE.SR",name:"主连",tick:1,multiplier:10,last:nil,bid:nil,ask:nil)
        precondition(!invalid.hasMetadata)
        let encoded = try JSONEncoder().encode(l)
        let decoded = try JSONDecoder().decode(PaperLedger.self,from:encoded)
        precondition(decoded == l)
        print("Paper order lifecycle, margin, close reservation, tick and persistence passed")
    }
}
