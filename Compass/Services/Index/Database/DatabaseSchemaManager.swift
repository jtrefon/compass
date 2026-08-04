import Foundation
import SQLite3

final class DatabaseSchemaManager {
    private unowned let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func createTables() throws {
        try createBaseSchema()
        try applyMigrations()
    }

    private func createBaseSchema() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS resources (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            language TEXT NOT NULL,
            last_modified REAL NOT NULL,
            content_hash TEXT,
            quality_score REAL,
            quality_details TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_resources_path ON resources(path);

        -- Drop old tables that are no longer used (memories/code_chunks/FTS)
        DROP TABLE IF EXISTS resources_fts;
        DROP TABLE IF EXISTS code_chunks;
        DROP TABLE IF EXISTS memory_embeddings;
        DROP TABLE IF EXISTS memories;

        -- Legacy symbols table — still queried by searchSymbols/searchSymbolsWithPaths
        -- protocol methods. The new 3-table schema (symbol_names/details/locations)
        -- is populated in parallel and queried by locate_symbol/inspect_symbol/where_symbol.
        CREATE TABLE IF NOT EXISTS symbols (
            id TEXT PRIMARY KEY,
            resource_id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            line_start INTEGER NOT NULL,
            line_end INTEGER NOT NULL,
            description TEXT,
            FOREIGN KEY(resource_id) REFERENCES resources(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
        CREATE INDEX IF NOT EXISTS idx_symbols_resource_id ON symbols(resource_id);

        -- New 3-table symbol schema (populated by IndexerActor.insertSymbols)
        CREATE TABLE IF NOT EXISTS symbol_names (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS symbol_details (
            id INTEGER PRIMARY KEY REFERENCES symbol_names(id),
            kind TEXT NOT NULL,
            scope TEXT DEFAULT '',
            signature TEXT DEFAULT '',
            parent_name TEXT DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_details_kind ON symbol_details(kind);
        CREATE INDEX IF NOT EXISTS idx_details_parent ON symbol_details(parent_name);

        CREATE TABLE IF NOT EXISTS symbol_locations (
            symbol_id INTEGER NOT NULL REFERENCES symbol_names(id),
            file_path TEXT NOT NULL,
            line_start INTEGER NOT NULL,
            line_end INTEGER DEFAULT 0,
            PRIMARY KEY (symbol_id, file_path, line_start)
        );
        CREATE INDEX IF NOT EXISTS idx_locations_file ON symbol_locations(file_path);
        """
        try database.execute(sql: sql)
    }

    private func applyMigrations() throws {
        try ensureColumnExists(table: "resources", column: "content_hash", columnDefinition: "TEXT")
        try ensureColumnExists(table: "resources", column: "quality_score", columnDefinition: "REAL NOT NULL DEFAULT 0")
        try ensureColumnExists(table: "resources", column: "quality_details", columnDefinition: "TEXT")
        try ensureColumnExists(
            table: "resources",
            column: "ai_enriched",
            columnDefinition: "INTEGER NOT NULL DEFAULT 0"
        )
        try ensureColumnExists(table: "resources", column: "summary", columnDefinition: "TEXT")
    }

    private func ensureColumnExists(table: String, column: String, columnDefinition: String) throws {
        let sql = "PRAGMA table_info(\(table));"
        var existingColumns = Set<String>()

        try database.withPreparedStatement(sql: sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(statement, 1) {
                    existingColumns.insert(String(cString: namePtr))
                }
            }
        }

        guard !existingColumns.contains(column) else { return }
        try database.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(columnDefinition);")
    }
}
