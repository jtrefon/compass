import Foundation

/// A single mask-and-fill site: real code with the "next line" removed.
///
/// `prefix` is everything before the cursor, `suffix` everything after.
/// The model must generate exactly the `expected` line (trimmed) to score
/// an exact match. Sites model what a developer would actually type next.
struct FIMBenchmarkSample: Sendable {
    let language: String
    let label: String
    let prefix: String
    let suffix: String
    let expected: String
}

/// Benchmark corpus for FIM quality. Not a test — pure data.
enum FIMBenchmarkFixtures {
    /// Brace languages get a structural-validity heuristic (balanced braces).
    static let braceLanguages: Set<String> = [
        "Swift", "C", "C++", "C#", "JavaScript", "TypeScript", "Java", "Rust", "PHP"
    ]

    static let samples: [FIMBenchmarkSample] = [
        // MARK: Swift
        .init(language: "Swift", label: "for-loop accumulate",
              prefix: "func sum(_ xs: [Int]) -> Int {\n    var total = 0\n    for x in xs {\n",
              suffix: "    }\n    return total\n}\n",
              expected: "        total += x"),
        .init(language: "Swift", label: "computed property",
              prefix: "final class Counter {\n    private var count = 0\n\n    func increment() {\n        count += 1\n    }\n\n    var value: Int {\n",
              suffix: "    }\n}\n",
              expected: "        count"),
        .init(language: "Swift", label: "coding keys",
              prefix: "struct Weather: Decodable {\n    let temperature: Double\n    let condition: String\n\n    enum CodingKeys: String, CodingKey {\n        case temperature\n        case condition\n",
              suffix: "    }\n}\n",
              expected: "        case cityName = \"city\""),
        .init(language: "Swift", label: "guard early return",
              prefix: "func describe(_ value: Int?) -> String {\n    guard let value else {\n",
              suffix: "    }\n    return \"value: \\(value)\"\n}\n",
              expected: "        return \"nil\""),
        .init(language: "Swift", label: "filter map",
              prefix: "let doubled = values\n    .filter { $0 > 0 }\n    .map { ",
              suffix: " }\n",
              expected: "$0 * 2"),

        // MARK: C
        .init(language: "C", label: "if branch return",
              prefix: "int max(int a, int b) {\n    if (a > b) {\n",
              suffix: "    }\n    return b;\n}\n",
              expected: "        return a;"),
        .init(language: "C", label: "loop accumulate",
              prefix: "int sum_array(int *arr, int n) {\n    int total = 0;\n    for (int i = 0; i < n; i++) {\n",
              suffix: "    }\n    return total;\n}\n",
              expected: "        total += arr[i];"),
        .init(language: "C", label: "pointer walk",
              prefix: "size_t my_strlen(const char *s) {\n    size_t len = 0;\n    while (*s != '\\0') {\n",
              suffix: "    }\n    return len;\n}\n",
              expected: "        len++;\n        s++;"),
        .init(language: "C", label: "null check",
              prefix: "void free_if_allocated(void **ptr) {\n    if (*ptr == NULL) {\n",
              suffix: "    }\n    free(*ptr);\n    *ptr = NULL;\n}\n",
              expected: "        return;"),

        // MARK: C++
        .init(language: "C++", label: "string join loop",
              prefix: "std::string join(const std::vector<std::string>& parts, const std::string& sep) {\n    std::string out;\n    for (size_t i = 0; i < parts.size(); i++) {\n        if (i > 0) out += sep;\n",
              suffix: "    }\n    return out;\n}\n",
              expected: "        out += parts[i];"),
        .init(language: "C++", label: "member function",
              prefix: "class Rectangle {\nprivate:\n    double w, h;\npublic:\n    double area() const {\n        return w * h;\n    }\n\n    double perimeter() const {\n",
              suffix: "    }\n};\n",
              expected: "        return 2 * (w + h);"),
        .init(language: "C++", label: "range loop",
              prefix: "double average(const std::vector<double>& v) {\n    if (v.empty()) return 0.0;\n    double total = 0.0;\n    for (double x : v) {\n",
              suffix: "    }\n    return total / v.size();\n}\n",
              expected: "        total += x;"),
        .init(language: "C++", label: "unique_ptr init",
              prefix: "#include <memory>\n\nstruct Config { int port; };\n\nint main() {\n    auto cfg = std::make_unique<Config>();\n    cfg->port = 8080;\n    ",
              suffix: ";\n    return 0;\n}\n",
              expected: "return cfg->port"),

        // MARK: C#
        .init(language: "C#", label: "foreach accumulate",
              prefix: "public int Sum(int[] xs) {\n    var total = 0;\n    foreach (var x in xs) {\n",
              suffix: "    }\n    return total;\n}\n",
              expected: "        total += x;"),
        .init(language: "C#", label: "null-or-empty guard",
              prefix: "public string Greet(string name) {\n    if (string.IsNullOrEmpty(name)) {\n",
              suffix: "    }\n    return $\"Hello, {name}!\";\n}\n",
              expected: "        return \"Hello, world!\";"),
        .init(language: "C#", label: "LINQ chain",
              prefix: "public int[] Doubles(int[] xs) {\n    return xs.Where(x => x > 0).Select(x => ",
              suffix: ").ToArray();\n}\n",
              expected: "x * 2"),
        .init(language: "C#", label: "property pattern",
              prefix: "public class Config {\n    public string Host { get; set; }\n    public int Port { get; set; }\n\n    public bool IsValid() {\n",
              suffix: "    }\n}\n",
              expected: "        return !string.IsNullOrEmpty(Host) && Port > 0;"),

        // MARK: JavaScript
        .init(language: "JavaScript", label: "recursion tail",
              prefix: "function fibonacci(n) {\n    if (n <= 1) {\n        return n;\n    }\n    return fibonacci(n - 1) + ",
              suffix: ";\n}\n",
              expected: "fibonacci(n - 2)"),
        .init(language: "JavaScript", label: "map chain",
              prefix: "const doubled = numbers\n    .filter(n => n % 2 === 0)\n    .map(n => ",
              suffix: ");\n",
              expected: "n * 2"),
        .init(language: "JavaScript", label: "closure counter",
              prefix: "function makeCounter() {\n    let count = 0;\n    return function () {\n        count += 1;\n",
              suffix: "    };\n}\n",
              expected: "        return count;"),
        .init(language: "JavaScript", label: "object guard",
              prefix: "function getConfig() {\n    const cfg = loadFromDisk();\n    if (!cfg) {\n",
              suffix: "    }\n    return cfg;\n}\n",
              expected: "        return defaultConfig;"),
        .init(language: "JavaScript", label: "async error",
              prefix: "async function fetchUser(id) {\n    const res = await fetch(`/api/users/${id}`);\n    if (!res.ok) {\n",
              suffix: "    }\n    return res.json();\n}\n",
              expected: "        throw new Error(`HTTP ${res.status}`);"),

        // MARK: TypeScript
        .init(language: "TypeScript", label: "union type",
              prefix: "interface User {\n    id: number;\n    name: string;\n    email: string;\n    role: ",
              suffix: ";\n}\n",
              expected: "'admin' | 'user'"),
        .init(language: "TypeScript", label: "generic stack pop",
              prefix: "class Stack<T> {\n    private items: T[] = [];\n\n    push(item: T): void {\n        this.items.push(item);\n    }\n\n    pop(): T | undefined {\n",
              suffix: "    }\n}\n",
              expected: "        return this.items.pop();"),
        .init(language: "TypeScript", label: "reduce init",
              prefix: "export function totalLength(words: string[]): number {\n    return words.reduce((acc, w) => acc + w.length, ",
              suffix: ");\n}\n",
              expected: "0"),
        .init(language: "TypeScript", label: "async guard",
              prefix: "async function loadUser(id: string): Promise<User> {\n    const user = await db.find(id);\n    if (!user) {\n",
              suffix: "    }\n    return user;\n}\n",
              expected: "        throw new Error('User not found');"),

        // MARK: Java
        .init(language: "Java", label: "method body",
              prefix: "public class Calculator {\n    public int add(int a, int b) {\n        return a + b;\n    }\n\n    public int multiply(int a, int b) {\n",
              suffix: "    }\n}\n",
              expected: "        return a * b;"),
        .init(language: "Java", label: "string builder loop",
              prefix: "public String format(int[] nums) {\n    StringBuilder sb = new StringBuilder();\n    for (int n : nums) {\n        if (sb.length() > 0) sb.append(\",\");\n        ",
              suffix: "\n    }\n    return sb.toString();\n}\n",
              expected: "sb.append(n);"),
        .init(language: "Java", label: "null check",
              prefix: "public int safeLength(String s) {\n    if (s == null) {\n",
              suffix: "    }\n    return s.length();\n}\n",
              expected: "        return 0;"),
        .init(language: "Java", label: "optional orElse",
              prefix: "import java.util.Optional;\n\npublic String nameOrUnknown(Optional<String> name) {\n    return name.orElse(",
              suffix: ");\n}\n",
              expected: "\"unknown\""),

        // MARK: Rust
        .init(language: "Rust", label: "max loop",
              prefix: "fn largest<T: PartialOrd + Copy>(list: &[T]) -> T {\n    let mut largest = list[0];\n    for &item in list {\n        if item > largest {\n",
              suffix: "        }\n    }\n    largest\n}\n",
              expected: "            largest = item;"),
        .init(language: "Rust", label: "iterator sum",
              prefix: "fn main() {\n    let numbers = vec![1, 2, 3, 4];\n    let sum: i32 = numbers.iter().",
              suffix: ";\n    println!(\"sum: {}\", sum);\n}\n",
              expected: "sum()"),
        .init(language: "Rust", label: "match arm",
              prefix: "fn describe(n: u32) -> &'static str {\n    match n {\n        0 => \"zero\",\n        1 => \"one\",\n        ",
              suffix: "    }\n}\n",
              expected: "_ => \"many\""),
        .init(language: "Rust", label: "early return",
              prefix: "fn first_even(v: &[i32]) -> Option<i32> {\n    for &x in v {\n        if x % 2 == 0 {\n            return Some(x);\n        }\n    }\n",
              suffix: "}\n",
              expected: "    None"),

        // MARK: PHP
        .init(language: "PHP", label: "insert + id",
              prefix: "<?php\nfunction add_user($db, $name, $email) {\n    $stmt = $db->prepare('INSERT INTO users (name, email) VALUES (?, ?)');\n    $stmt->execute([$name, $email]);\n    return ",
              suffix: ";\n}\n",
              expected: "$db->lastInsertId()"),
        .init(language: "PHP", label: "assoc config",
              prefix: "<?php\n$config = [\n    'host' => 'localhost',\n    'port' => 3306,\n    'charset' => 'utf8mb4',\n",
              suffix: "];\n",
              expected: "    'timeout' => 5,"),
        .init(language: "PHP", label: "null coalesce",
              prefix: "<?php\nfunction get_env($key, $default = null) {\n    $value = getenv($key);\n    return $value === false ? ",
              suffix: " : $value;\n}\n",
              expected: "$default"),
        .init(language: "PHP", label: "foreach map",
              prefix: "<?php\nfunction normalize($rows) {\n    $out = [];\n    foreach ($rows as $row) {\n",
              suffix: "\n    }\n    return $out;\n}\n",
              expected: "        $out[] = strtolower($row);"),

        // MARK: HTML
        .init(language: "HTML", label: "nav item",
              prefix: "<!DOCTYPE html>\n<html>\n<head>\n    <title>Dashboard</title>\n</head>\n<body>\n    <nav>\n        <ul>\n            <li><a href=\"#\">Home</a></li>\n            <li><a href=\"#\">Settings</a></li>\n",
              suffix: "        </ul>\n    </nav>\n</body>\n</html>\n",
              expected: "            <li><a href=\"#\">Profile</a></li>"),
        .init(language: "HTML", label: "form fields",
              prefix: "    <form action=\"/login\" method=\"post\">\n        <label for=\"username\">Username</label>\n        <input type=\"text\" id=\"username\" name=\"username\">\n        <label for=\"password\">Password</label>\n",
              suffix: "        <button type=\"submit\">Login</button>\n    </form>\n",
              expected: "        <input type=\"password\" id=\"password\" name=\"password\">"),
        .init(language: "HTML", label: "list item",
              prefix: "<ul class=\"items\">\n    <li class=\"item\">Apple</li>\n    <li class=\"item\">Banana</li>\n",
              suffix: "</ul>\n",
              expected: "    <li class=\"item\">Cherry</li>"),
        .init(language: "HTML", label: "meta pair",
              prefix: "<head>\n    <meta charset=\"UTF-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n    <meta name=\"description\" content=\"Product page\">\n    ",
              suffix: "\n</head>\n",
              expected: "<title>Product</title>"),

        // MARK: CSS
        .init(language: "CSS", label: "hover rule",
              prefix: ".card {\n    background: #fff;\n    border-radius: 8px;\n    padding: 16px;\n    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);\n}\n\n.card:hover {\n",
              suffix: "}\n",
              expected: "    transform: translateY(-2px);"),
        .init(language: "CSS", label: "media query",
              prefix: "@media (max-width: 768px) {\n    .container {\n        flex-direction: column;\n",
              suffix: "    }\n}\n",
              expected: "        padding: 0 16px;"),
        .init(language: "CSS", label: "flex center",
              prefix: ".modal {\n    display: flex;\n    align-items: center;\n    justify-content: center;\n    ",
              suffix: ";\n}\n",
              expected: "height: 100vh"),
        .init(language: "CSS", label: "button colors",
              prefix: ".btn-primary {\n    background-color: #007bff;\n    color: #fff;\n    border: none;\n    padding: 8px 16px;\n    border-radius: 4px;\n    cursor: pointer;\n}\n\n.btn-primary:hover {\n",
              suffix: "}\n",
              expected: "    background-color: #0056b3;"),

        // MARK: Perl
        .init(language: "Perl", label: "hash config",
              prefix: "#!/usr/bin/perl\nuse strict;\nuse warnings;\n\nmy %config = (\n    host => 'localhost',\n    port => 8080,\n    workers => 4,\n",
              suffix: ");\n",
              expected: "    timeout => 30,"),
        .init(language: "Perl", label: "split return",
              prefix: "sub process_line {\n    my ($line) = @_;\n    chomp $line;\n    my ($name, $value) = split /=/, $line, 2;\n    return ",
              suffix: ";\n}\n",
              expected: "($name, $value)"),
        .init(language: "Perl", label: "unless guard",
              prefix: "sub connect {\n    my ($dsn) = @_;\n    my $dbh = DBI->connect($dsn) or die $DBI::errstr;\n    unless ($dbh) {\n",
              suffix: "    }\n    return $dbh;\n}\n",
              expected: "        die \"connection failed\";"),
    ]
}
