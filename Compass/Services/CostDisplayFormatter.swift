import Foundation

enum CostDisplayFormatter {
    static func dollarAmount(fromMicrodollars microdollars: Int) -> String {
        let costDollars = Double(microdollars) / 1_000_000
        if costDollars == 0 {
            return "$0"
        }
        if costDollars < 0.01 {
            return String(format: "$%.4f", costDollars)
        }
        return String(format: "$%.2f", costDollars)
    }
}
