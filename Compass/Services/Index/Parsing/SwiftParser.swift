//
//  SwiftParser.swift
//  Compass
//
//  Created by Cascade on 23/12/2025.
//

import Foundation

public struct SwiftParser {
    public static func parse(content: String, resourceId: String) -> [Symbol] {
        return SwiftRegexParser.parse(content: content, resourceId: resourceId)
    }
}

private enum SwiftRegexParser {
    static func parse(content: String, resourceId: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = content.components(separatedBy: .newlines)

        let patterns: [(kind: SymbolKind, pattern: String)] = [
            (.class, #"^\s*(?:final\s+|public\s+|private\s+|open\s+|internal\s+)*class\s+([A-Z][a-zA-Z0-9_]*)"#),
            (.struct, #"^\s*(?:public\s+|private\s+|internal\s+)*struct\s+([A-Z][a-zA-Z0-9_]*)"#),
            (.enum, #"^\s*(?:public\s+|private\s+|internal\s+)*enum\s+([A-Z][a-zA-Z0-9_]*)"#),
            (.protocol, #"^\s*(?:public\s+|private\s+|internal\s+)*protocol\s+([A-Z][a-zA-Z0-9_]*)"#),
            (.extension, #"^\s*(?:public\s+|private\s+|internal\s+)*extension\s+([A-Z][a-zA-Z0-9_.]*)"#),
            (
                .function,
                #"^\s*(?:final\s+|override\s+|public\s+|private\s+|internal\s+|static\s+|class\s+)*func\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:<[^>]+>)?\s*\("#
            ),
            (.initializer, #"^\s*(?:public\s+|private\s+|internal\s+)*init\s*(?:\?|\!)?\s*\("#),
            (
                .variable,
                "^\\s*(?:public\\s+|private\\s+|internal\\s+|static\\s+|class\\s+|let\\s+|var\\s+)+" +
                    "(?:var|let)\\s+([a-zA-Z0-9_]+)"
            )
        ]

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1

            for (kind, pattern) in patterns {
                if let match = matchRegex(pattern, in: line) {
                    let name = (kind == .initializer) ? "init" : match
                    let id = "\(resourceId):\(lineNum):\(name)"

                    let symbol = Symbol(
                        id: id,
                        resourceId: resourceId,
                        name: name,
                        kind: kind,
                        lineStart: lineNum,
                        lineEnd: lineNum,
                        description: nil
                    )
                    symbols.append(symbol)
                    break
                }
            }
        }

        return symbols
    }

    private static func matchRegex(_ pattern: String, in text: String) -> String? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let nsString = text as NSString
            let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

            if let result = results.first {
                if result.numberOfRanges > 1 {
                    return nsString.substring(with: result.range(at: 1))
                }
                return ""
            }
        } catch {
        }
        return nil
    }
}
